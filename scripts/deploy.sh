#!/usr/bin/env bash
# Build, deploy and seed the whole platform. Idempotent: safe to run on every push.
#   PLATFORM=emulator ./scripts/deploy.sh   (Floci on localhost:4566 — default when AWS_PROFILE=floci)
#   PLATFORM=aws      ./scripts/deploy.sh   (real AWS account)
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK="${STACK:-exams-prod}"
REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$REGION"
if [ -z "${PLATFORM:-}" ]; then
  [ "${AWS_PROFILE:-}" = "floci" ] || [ -n "${AWS_ENDPOINT_URL:-}" ] && PLATFORM=emulator || PLATFORM=aws
fi
log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ARTIFACTS="${STACK}-artifacts-${ACCOUNT}"
log "Target: platform=$PLATFORM account=$ACCOUNT region=$REGION stack=$STACK"

log "1/6 Artifact bucket $ARTIFACTS"
aws s3api head-bucket --bucket "$ARTIFACTS" >/dev/null 2>&1 || aws s3api create-bucket --bucket "$ARTIFACTS" >/dev/null
aws s3api put-bucket-versioning --bucket "$ARTIFACTS" --versioning-configuration Status=Enabled

log "2/6 Build Lambda bundle"
cd "$ROOT/app/functions"
npm ci --omit=dev --no-audit --no-fund --silent
BUNDLE="$(mktemp -d)/functions.zip"
python3 - "$BUNDLE" <<'PY'
import os, sys, zipfile
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for top in ('src', 'node_modules', 'package.json'):
        paths = [top] if os.path.isfile(top) else sorted(os.path.join(d, f) for d, _, fs in os.walk(top) for f in fs)
        for p in paths:
            info = zipfile.ZipInfo(p, date_time=(2020, 1, 1, 0, 0, 0))   # fixed time => same code, same hash
            info.external_attr = 0o644 << 16
            z.writestr(info, open(p, 'rb').read(), zipfile.ZIP_DEFLATED)
PY
HASH=$(sha256sum "$BUNDLE" | cut -c1-16)
CODE_KEY="lambda/functions-${HASH}.zip"
aws s3 cp "$BUNDLE" "s3://$ARTIFACTS/$CODE_KEY" --only-show-errors
echo "bundle: s3://$ARTIFACTS/$CODE_KEY"
cd "$ROOT"

log "3/6 CloudFormation deploy (infra/cloudformation/exam-platform.yaml)"
aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file infra/cloudformation/exam-platform.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --tags Project=exam-platform Course=DSO303 \
  --parameter-overrides Platform="$PLATFORM" ArtifactBucket="$ARTIFACTS" CodeKey="$CODE_KEY"

out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
API_ID=$(out HttpApiId); POOL=$(out UserPoolId); CLIENT=$(out UserPoolClientId)
FRONTEND=$(out FrontendBucket); EXAMS=$(out ExamsTable); MIGRATE=$(out MigrateFunction)

# Floci only: make sure every function runs the bundle just uploaded (CloudFormation on the
# emulator may skip code updates when only the S3 key changes).
if [ "$PLATFORM" = "emulator" ]; then
  for f in exam-api marker upload-processor notifier db-migrate; do
    aws lambda update-function-code --function-name "$STACK-$f" --s3-bucket "$ARTIFACTS" --s3-key "$CODE_KEY" >/dev/null
  done
  echo "Applying settings Floci's CloudFormation ignores:"
  "$ROOT/scripts/floci-reconcile.sh"
fi

log "4/6 Database migration (Lambda $MIGRATE)"
for i in 1 2 3 4 5 6; do
  if aws lambda invoke --function-name "$MIGRATE" --cli-read-timeout 300 /tmp/a2-migrate.json >/dev/null 2>&1 \
     && ! grep -q errorMessage /tmp/a2-migrate.json; then cat /tmp/a2-migrate.json; echo; break; fi
  echo "migration attempt $i not ready yet: $(head -c 200 /tmp/a2-migrate.json 2>/dev/null)"; sleep 15
  [ "$i" = 6 ] && { echo "migration failed"; exit 1; }
done

log "5/6 Seed exam paper and demo users"
python3 - "$ROOT/scripts/seed/exam-DSO303-MIDTERM.json" > /tmp/a2-exam-item.json <<'PY'
import json, sys
def ddb(v):
    if isinstance(v, bool): return {"BOOL": v}
    if isinstance(v, (int, float)): return {"N": str(v)}
    if isinstance(v, str): return {"S": v}
    if isinstance(v, list): return {"L": [ddb(x) for x in v]}
    if isinstance(v, dict): return {"M": {k: ddb(x) for k, x in v.items()}}
print(json.dumps({k: ddb(v) for k, v in json.load(open(sys.argv[1])).items()}))
PY
aws dynamodb put-item --table-name "$EXAMS" --item file:///tmp/a2-exam-item.json
aws dynamodb put-item --table-name "$EXAMS" --item '{"examId":{"S":"CATALOGUE"},"exams":{"L":[{"M":{"examId":{"S":"DSO303-MIDTERM"},"title":{"S":"DSO303 Cloud Architecture Mid-term"},"durationMinutes":{"N":"60"}}}]}}'

DEMO_PASSWORD="${DEMO_PASSWORD:-Exam-Demo-2026!}"
mkuser() { # username email group
  aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$1" >/dev/null 2>&1 || \
    aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$1" --message-action SUPPRESS \
      --user-attributes Name=email,Value="$2" Name=email_verified,Value=true >/dev/null
  aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$1" --password "$DEMO_PASSWORD" --permanent
  aws cognito-idp admin-add-user-to-group --user-pool-id "$POOL" --username "$1" --group-name "$3"
  echo "user $1 -> $3"
}
mkuser student1 student1@students.example.edu Students
mkuser student2 student2@students.example.edu Students
mkuser tutor1   tutor1@staff.example.edu       Tutors
mkuser admin1   admin1@staff.example.edu       Admins
[ "$PLATFORM" = "emulator" ] && aws ses verify-email-identity --email-address no-reply@exams.example.edu >/dev/null || true

log "6/6 Publish frontend to s3://$FRONTEND"
if [ "$PLATFORM" = "emulator" ]; then
  API_BASE="http://localhost:4566/restapis/$API_ID/\$default/_user_request_"; COGNITO="http://localhost:4566/"
else
  API_BASE=""; COGNITO="https://cognito-idp.$REGION.amazonaws.com/"
fi
cat > "$ROOT/app/frontend/config.js" <<CFG
// Generated by scripts/deploy.sh — do not edit.
window.APP_CONFIG = { apiBase: "$API_BASE", cognitoEndpoint: "$COGNITO", userPoolClientId: "$CLIENT", region: "$REGION", platform: "$PLATFORM" };
CFG
aws s3 sync "$ROOT/app/frontend" "s3://$FRONTEND" --delete --only-show-errors --cache-control "no-cache"

log "Deployed"
if [ "$PLATFORM" = "emulator" ]; then
  echo "Frontend : http://localhost:4566/$FRONTEND/index.html"
  echo "API      : $API_BASE/api/health"
else
  echo "Frontend : https://$(out DistributionDomain)  (and https://<DomainName> once NS records are delegated)"
fi
echo "Users    : student1 / student2 / tutor1 / admin1   password: $DEMO_PASSWORD"
