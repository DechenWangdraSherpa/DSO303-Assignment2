#!/usr/bin/env bash
# Reads the deployed environment back and checks the architecture requirements:
# tiers across two AZs, private database, encryption at rest, retention, edge, monitoring.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
VPC=$(out VpcId); CL=$(out AuroraClusterId); SUB=$(out SubmissionsBucket)

step "Network: three subnet tiers mirrored in two Availability Zones ($VPC)"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].[Tags[?Key==`Tier`]|[0].Value,AvailabilityZone,CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output text | sort | awk '{printf "  %-13s %-11s %-15s %s\n",$1,$2,$3,$4}'
aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$VPC" --query 'NatGateways[].[Tags[?Key==`Name`]|[0].Value,State]' --output text | sed 's/^/  NAT  /'
for rt in rt-public rt-app-a rt-app-b rt-data-isolated; do
  r=$(aws ec2 describe-route-tables --filters "Name=tag:Name,Values=$STACK-$rt" --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId||NatGatewayId]' --output text)
  printf "  route table %-18s 0.0.0.0/0 -> %s\n" "$rt" "${r:-NONE (isolated)}"
done
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" --query 'VpcEndpoints[].[ServiceName,VpcEndpointType]' --output text | sed 's/^/  endpoint /'
SGDB=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$STACK-sg-aurora" --query 'SecurityGroups[0].IpPermissions[0].[FromPort,UserIdGroupPairs[0].GroupId]' --output text)
SGL=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=$STACK-sg-lambda" --query 'SecurityGroups[0].GroupId' --output text)
echo "  sg-aurora ingress: tcp/$(echo $SGDB | cut -d' ' -f1) only from $(echo $SGDB | cut -d' ' -f2) (= sg-lambda $SGL)"

step "Compute: every Lambda runs in the private app subnets of both AZs"
for f in exam-api marker upload-processor notifier db-migrate; do
  s=$(aws lambda get-function-configuration --function-name "$STACK-$f" --query 'VpcConfig.SubnetIds' --output text)
  azs=$(aws ec2 describe-subnets --subnet-ids $s --query 'Subnets[].AvailabilityZone' --output text | tr '\t' ',')
  printf "  %-28s %s  subnets in %s\n" "$STACK-$f" "$(aws lambda get-function-configuration --function-name "$STACK-$f" --query '[Runtime,Architectures[0]]' --output text | tr '\t' '/')" "$azs"
done

step "Database: Aurora PostgreSQL, private, encrypted, writer + reader"
aws rds describe-db-clusters --db-cluster-identifier "$CL" --query 'DBClusters[0].[Engine,EngineVersion,StorageEncrypted,BackupRetentionPeriod]' --output text | awk '{print "  engine "$1" "$2"  encrypted="$3"  backup retention="$4" days"}'
aws rds describe-db-clusters --db-cluster-identifier "$CL" --query 'DBClusters[0].DBClusterMembers[].[DBInstanceIdentifier,IsClusterWriter]' --output text | awk '{printf "  %-30s %s\n",$1,($2=="True"?"WRITER":"reader (failover target)")}'
aws rds describe-db-subnet-groups --query "DBSubnetGroups[?VpcId=='$VPC'].Subnets[].SubnetAvailabilityZone.Name" --output text | sed 's/^/  DB subnet group AZs: /'
aws rds describe-db-instances --query "DBInstances[?DBClusterIdentifier=='$CL'].[DBInstanceIdentifier,PubliclyAccessible]" --output text | awk '{print "  "$1" publicly accessible: "$2}'

step "Data at rest: DynamoDB, S3, SQS, Secrets Manager (KMS key alias/$STACK-data)"
for t in $(out ExamsTable) $(out AttemptsTable); do
  printf "  dynamodb %-22s billing=%s  SSE=%s  PITR=%s\n" "$t" \
    "$(aws dynamodb describe-table --table-name $t --query 'Table.BillingModeSummary.BillingMode' --output text)" \
    "$(aws dynamodb describe-table --table-name $t --query 'Table.SSEDescription.SSEType' --output text)" \
    "$(aws dynamodb describe-continuous-backups --table-name $t --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text)"
done
echo "  s3 $SUB: encryption=$(aws s3api get-bucket-encryption --bucket $SUB --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text) versioning=$(aws s3api get-bucket-versioning --bucket $SUB --query Status --output text) block-public=$(aws s3api get-public-access-block --bucket $SUB --query 'PublicAccessBlockConfiguration.BlockPublicPolicy' --output text) lifecycle-rules=$(aws s3api get-bucket-lifecycle-configuration --bucket $SUB --query 'length(Rules)')"
for q in marking upload-events notify; do
  url=$(aws sqs get-queue-url --queue-name "$STACK-$q" --query QueueUrl --output text)
  a=$(aws sqs get-queue-attributes --queue-url "$url" --attribute-names KmsMasterKeyId SqsManagedSseEnabled RedrivePolicy --output json)
  echo "  sqs $STACK-$q: encryption=$(echo "$a" | python3 -c 'import json,sys;a=json.load(sys.stdin)["Attributes"];print("KMS" if a.get("KmsMasterKeyId") else ("SQS-managed" if a.get("SqsManagedSseEnabled")=="true" else "none"))') DLQ=$(echo "$a" | python3 -c 'import json,sys;print(json.loads(json.load(sys.stdin)["Attributes"]["RedrivePolicy"])["deadLetterTargetArn"].split(":")[-1])')"
done
K=$(aws kms describe-key --key-id "alias/$STACK-data" --query KeyMetadata.KeyId --output text)
echo "  kms alias/$STACK-data: state=$(aws kms describe-key --key-id $K --query KeyMetadata.KeyState --output text) rotation=$(aws kms get-key-rotation-status --key-id $K --query KeyRotationEnabled --output text)"
echo "  secret $STACK/aurora/master encrypted with: $(aws secretsmanager describe-secret --secret-id $STACK/aurora/master --query KmsKeyId --output text | sed 's#.*/##')"

step "Edge, identity, operations"
echo "  CloudFront: $(aws cloudfront list-distributions --query 'DistributionList.Items[0].[Id,Status]' --output text | tr '\t' ' ')  WAF ACL: $(aws wafv2 list-web-acls --scope CLOUDFRONT --query 'WebACLs[0].Name' --output text) ($(aws wafv2 get-web-acl --scope CLOUDFRONT --name $STACK-edge-acl --id $(aws wafv2 list-web-acls --scope CLOUDFRONT --query 'WebACLs[0].Id' --output text) --query 'length(WebACL.Rules)') rules)"
echo "  Route 53 zone: $(aws route53 list-hosted-zones --query 'HostedZones[0].Name' --output text)   Cognito groups: $(aws cognito-idp list-groups --user-pool-id $POOL --query 'Groups[].GroupName' --output text | tr '\t' ',')"
echo "  CloudWatch alarms: $(aws cloudwatch describe-alarms --alarm-name-prefix $STACK --query 'length(MetricAlarms)')   dashboard: $(aws cloudwatch list-dashboards --query 'DashboardEntries[0].DashboardName' --output text)   trail: $(aws cloudtrail describe-trails --query 'trailList[0].Name' --output text)"
echo "  AWS Backup: $(aws backup list-backup-plans --query 'BackupPlansList[0].BackupPlanName' --output text) -> vault $(aws backup list-backup-vaults --query 'BackupVaultList[0].BackupVaultName' --output text)"
ok "verification finished"
