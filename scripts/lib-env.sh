# shellcheck shell=bash
# Sourced by the simulate-*.sh scripts: stack outputs, sign-in and pretty printing.
export AWS_PROFILE="${AWS_PROFILE:-floci}" AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK:-exams-prod}"
DEMO_PASSWORD="${DEMO_PASSWORD:-Exam-Demo-2026!}"
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }
API_ID=$(out HttpApiId); CLIENT=$(out UserPoolClientId); POOL=$(out UserPoolId)
API="http://localhost:4566/restapis/$API_ID/\$default/_user_request_/api"
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m✘ %s\033[0m\n' "$*"; }
signin() { # username -> prints ID token (Cognito USER_PASSWORD_AUTH)
  curl -s http://localhost:4566/ -H 'content-type: application/x-amz-json-1.1' \
    -H 'x-amz-target: AWSCognitoIdentityProviderService.InitiateAuth' \
    -d "{\"AuthFlow\":\"USER_PASSWORD_AUTH\",\"ClientId\":\"$CLIENT\",\"AuthParameters\":{\"USERNAME\":\"$1\",\"PASSWORD\":\"$DEMO_PASSWORD\"}}" \
  | python3 -c 'import json,sys;print(json.load(sys.stdin)["AuthenticationResult"]["IdToken"])'
}
call() { # METHOD PATH TOKEN [JSON] -> body, prints "HTTP nnn" to stderr
  local m=$1 p=$2 t=$3 d=${4:-}
  curl -s -m 120 -X "$m" "$API$p" -H "authorization: Bearer $t" -H 'content-type: application/json' ${d:+-d "$d"} -w '\n%{http_code}' \
  | { body=$(cat); code=${body##*$'\n'}; echo "${body%$'\n'*}"; echo "HTTP $code" >&2; }
}
pj() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d, indent=2, default=str)[:'"${1:-1500}"'])'; }
