#!/usr/bin/env bash
# Remove everything deploy.sh created. Buckets are versioned, so every version is deleted first.
#   ./scripts/teardown.sh            (asks for confirmation)
#   ./scripts/teardown.sh --yes      (CI / scripted)
set -Eeuo pipefail
STACK="${STACK:-exams-prod}"
export AWS_DEFAULT_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[ "${1:-}" = "--yes" ] || { read -r -p "Delete stack $STACK and all its data in account $ACCOUNT? [y/N] " a; [ "$a" = y ] || exit 1; }

empty_bucket() {
  aws s3api head-bucket --bucket "$1" >/dev/null 2>&1 || return 0
  echo "emptying s3://$1"
  aws s3 rm "s3://$1" --recursive --only-show-errors || true
  while :; do
    v=$(aws s3api list-object-versions --bucket "$1" --max-items 500 --output json \
        --query '{Objects: [Versions[].{Key:Key,VersionId:VersionId}, DeleteMarkers[].{Key:Key,VersionId:VersionId}][]}')
    [ "$(echo "$v" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["Objects"] or []))')" = 0 ] && break
    aws s3api delete-objects --bucket "$1" --delete "$v" >/dev/null
  done
}
for b in frontend submissions logs; do empty_bucket "$STACK-$b-$ACCOUNT"; done

# Aurora has deletion protection on AWS; switch it off so the stack can go.
aws rds modify-db-cluster --db-cluster-identifier "$STACK-aurora" --no-deletion-protection --apply-immediately >/dev/null 2>&1 || true

echo "deleting stack $STACK"
aws cloudformation delete-stack --stack-name "$STACK"
aws cloudformation wait stack-delete-complete --stack-name "$STACK"

empty_bucket "$STACK-artifacts-$ACCOUNT"
aws s3api delete-bucket --bucket "$STACK-artifacts-$ACCOUNT" 2>/dev/null || true
echo "Teardown complete. (Aurora leaves a final snapshot because of DeletionPolicy: Snapshot.)"
echo "Local emulator: ./scripts/floci-down.sh --purge also wipes Floci's state."
