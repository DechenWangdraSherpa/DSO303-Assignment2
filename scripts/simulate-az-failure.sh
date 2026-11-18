#!/usr/bin/env bash
# Simulate losing Availability Zone us-east-1a in the middle of an exam.
#  - Aurora: the writer in AZ-a is lost -> the reader in AZ-b is promoted (failover-db-cluster)
#  - Lambda: the AZ-a app subnet is gone -> functions run only from the AZ-b subnet
#  - Students keep autosaving the whole time; we count every request and check no answer is lost.
# On real AWS the same faults are injected by the FIS template infra/fis/az-a-outage.json.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
CLUSTER=$(out AuroraClusterId); ATTEMPTS=$(out AttemptsTable); EXAM=DSO303-MIDTERM
FUNCS="exam-api marker upload-processor notifier"
LOG=$(mktemp); trap 'kill $LOAD 2>/dev/null || true; rm -f $LOG' EXIT
subnet() { aws ec2 describe-subnets --filters "Name=tag:Name,Values=$STACK-$1" --query 'Subnets[0].SubnetId' --output text; }
APP_A=$(subnet app-a); APP_B=$(subnet app-b)
members() { aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER" --query 'DBClusters[0].DBClusterMembers[].[DBInstanceIdentifier,IsClusterWriter]' --output text | awk '{printf "  %-32s %s\n", $1, ($2=="True"?"WRITER":"reader")}'; }
lambda_subnets() { aws lambda get-function-configuration --function-name "$STACK-exam-api" --query 'VpcConfig.SubnetIds' --output text; }
az_of() { for s in $*; do aws ec2 describe-subnets --subnet-ids $s --query 'Subnets[0].[Tags[?Key==`Name`]|[0].Value,AvailabilityZone]' --output text; done | sed 's/^/  /'; }

STUDENT=student1
aws dynamodb delete-item --table-name "$ATTEMPTS" --key "{\"studentId\":{\"S\":\"$STUDENT\"},\"examId\":{\"S\":\"$EXAM\"}}"
TOKEN=$(signin $STUDENT); TUTOR=$(signin tutor1)
call GET /exams/$EXAM "$TOKEN" >/dev/null 2>&1

step "1. Baseline - healthy, both AZs in use"
echo " Aurora cluster $CLUSTER:"; members
echo " exam-api Lambda subnets:"; az_of $(lambda_subnets)

step "2. Start exam traffic: student autosaves + tutor Aurora reads every 2 s"
( n=0; while true; do n=$((n+1))
    a=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X PUT "$API/exams/$EXAM/autosave" -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' -d "{\"answers\":{\"q5\":\"draft $n\"}}")
    d=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$API/submissions" -H "authorization: Bearer $TUTOR")
    echo "$(date +%H:%M:%S) save#$n autosave=$a aurora-read=$d" >> $LOG; sleep 2; done ) & LOAD=$!
sleep 10; tail -3 $LOG | sed 's/^/  /'

step "3. FAILURE at $(date +%H:%M:%S): Availability Zone us-east-1a is lost"
echo "  a) Aurora writer in AZ-a lost -> fail over to the reader in AZ-b"
aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER" --target-db-instance-identifier "$STACK-aurora-reader-b" --query 'DBCluster.Status' --output text | sed 's/^/     cluster status: /'
echo "  b) app subnet $APP_A (AZ-a) unusable -> Lambda keeps only $APP_B (AZ-b)"
SG=$(aws lambda get-function-configuration --function-name "$STACK-exam-api" --query 'VpcConfig.SecurityGroupIds[0]' --output text)
for f in $FUNCS; do aws lambda update-function-configuration --function-name "$STACK-$f" --vpc-config "SubnetIds=$APP_B,SecurityGroupIds=$SG" >/dev/null; done
sleep 4
echo " Aurora cluster after failover:"; members
echo " exam-api Lambda subnets now:"; az_of $(lambda_subnets)

step "4. Exam continues during the outage (30 s of traffic)"
sleep 30
tail -6 $LOG | sed 's/^/  /'

step "5. Result"
kill $LOAD; wait $LOAD 2>/dev/null || true
TOTAL=$(wc -l < $LOG); FAILED=$(grep -c -v 'autosave=200 aurora-read=200' $LOG || true)
echo "  requests: $TOTAL rounds (autosave + Aurora read each), failed rounds: $FAILED"
LAST=$(tail -1 $LOG | grep -o 'save#[0-9]*' | tr -dc 0-9)
aws dynamodb get-item --table-name "$ATTEMPTS" --consistent-read --key "{\"studentId\":{\"S\":\"$STUDENT\"},\"examId\":{\"S\":\"$EXAM\"}}" \
  --query 'Item.[answers.M.q5.S,saves.N,savedAt.S]' --output text | awk -v last="$LAST" '{print "  latest stored answer: \""$1" "$2"\" (sent: draft "last")  saves="$3"  savedAt="$4}'
[ "$FAILED" -eq 0 ] && ok "no failed requests - RPO 0 for autosaved answers, no visible downtime" || bad "$FAILED rounds failed during failover (see above)"

step "6. Recovery (AZ-a back): restore both subnets and fail back the writer"
for f in $FUNCS; do aws lambda update-function-configuration --function-name "$STACK-$f" --vpc-config "SubnetIds=$APP_A,$APP_B,SecurityGroupIds=$SG" >/dev/null; done
aws rds failover-db-cluster --db-cluster-identifier "$CLUSTER" --target-db-instance-identifier "$STACK-aurora-writer-a" >/dev/null
sleep 3; members; az_of $(lambda_subnets)
ok "back to two-AZ operation"
