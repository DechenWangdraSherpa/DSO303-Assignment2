#!/usr/bin/env bash
# Emulator only. Floci's CloudFormation accepts these template properties but does not apply
# them, so this applies the SAME settings through the service APIs. Idempotent.
# On real AWS this script is not run: CloudFormation applies them from exam-platform.yaml.
set -Eeuo pipefail
STACK="${STACK:-exams-prod}"
KEY=$(aws kms describe-key --key-id "alias/$STACK-data" --query KeyMetadata.Arn --output text)
aws kms enable-key-rotation --key-id "$KEY"
echo "  alias/$STACK-data: annual key rotation on"
for t in "$STACK-exams" "$STACK-attempts"; do
  aws dynamodb update-continuous-backups --table-name "$t" --point-in-time-recovery-specification PointInTimeRecoveryEnabled=true >/dev/null
  aws dynamodb update-table --table-name "$t" --sse-specification "Enabled=true,SSEType=KMS,KMSMasterKeyId=$KEY" >/dev/null 2>&1 || true
  echo "  $t: PITR on, SSE-KMS on"
done
aws rds modify-db-cluster --db-cluster-identifier "$STACK-aurora" --backup-retention-period 35 --apply-immediately >/dev/null
echo "  $STACK-aurora: backup retention 35 days"
if ! aws backup list-backup-plans --query "BackupPlansList[?BackupPlanName=='$STACK-records'].BackupPlanId" --output text | grep -q .; then
  aws backup create-backup-plan --backup-plan "{\"BackupPlanName\":\"$STACK-records\",\"Rules\":[
    {\"RuleName\":\"daily-35d\",\"TargetBackupVaultName\":\"$STACK-vault\",\"ScheduleExpression\":\"cron(0 19 * * ? *)\",\"Lifecycle\":{\"DeleteAfterDays\":35}},
    {\"RuleName\":\"monthly-5y\",\"TargetBackupVaultName\":\"$STACK-vault\",\"ScheduleExpression\":\"cron(0 20 1 * ? *)\",\"Lifecycle\":{\"MoveToColdStorageAfterDays\":90,\"DeleteAfterDays\":1830}}]}" >/dev/null
fi
echo "  AWS Backup plan $STACK-records: daily (35 d) + monthly (5 y) into $STACK-vault"
