#!/usr/bin/env bash
# Walkthrough 1 - a student opens an exam and the answers autosave every 30 seconds.
#   AUTOSAVE_INTERVAL=30 ./scripts/simulate-walkthrough1.sh
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
EXAM=DSO303-MIDTERM; STUDENT=student2; INTERVAL="${AUTOSAVE_INTERVAL:-30}"
ATTEMPTS=$(out AttemptsTable)
aws dynamodb delete-item --table-name "$ATTEMPTS" --key "{\"studentId\":{\"S\":\"$STUDENT\"},\"examId\":{\"S\":\"$EXAM\"}}"  # fresh demo attempt

step "1. $STUDENT signs in with Cognito (USER_PASSWORD_AUTH) and receives a JWT"
TOKEN=$(signin $STUDENT)
python3 -c 'import json,sys,base64; p=sys.argv[1].split(".")[1]; c=json.loads(base64.urlsafe_b64decode(p+"="*(-len(p)%4)))
for k in ("cognito:username","cognito:groups","token_use","iss"): print(f"  {k:17}: {c[k]}")' "$TOKEN"
ok "signed in as $STUDENT"

step "2. Browser -> CloudFront/API Gateway -> exam-api Lambda: GET /api/exams/$EXAM"
OPEN=$(call GET /exams/$EXAM "$TOKEN")
echo "$OPEN" | python3 -c '
import json,sys; d=json.load(sys.stdin); a=d["attempt"]
print(f"exam     : {d["title"]} ({d["durationMinutes"]} min, {len(d["questions"])} questions)")
print(f"attempt  : status={a["status"]} startedAt={a["startedAt"]} endsAt={a["endsAt"]}")
leak=[q["id"] for q in d["questions"] if "answer" in q]
print("answer key sent to browser:", "NO (stripped by API)" if not leak else leak)'
ok "exam paper read from DynamoDB '$(out ExamsTable)'; attempt row created in '$ATTEMPTS'"

step "3. Student answers; the browser autosaves every ${INTERVAL}s (PUT /api/exams/$EXAM/autosave)"
ANS=('{"q1":"Presigned URL / POST"}'
     '{"q1":"Presigned URL / POST","q2":"A reader in another AZ is promoted to writer"}'
     '{"q1":"Presigned URL / POST","q2":"A reader in another AZ is promoted to writer","q3":"Amazon SQS queue","q5":"DynamoDB absorbs 100 writes/s with single-digit ms latency."}')
for i in 0 1 2; do
  [ $i -gt 0 ] && sleep "$INTERVAL"
  R=$(call PUT /exams/$EXAM/autosave "$TOKEN" "{\"answers\":${ANS[$i]}}" 2>/dev/null)
  echo "  $(date +%H:%M:%S)  autosave #$((i+1)) -> $R"
done
ok "3 autosaves accepted - at most ${INTERVAL}s of typing can ever be lost"

step "4. The autosaved attempt in DynamoDB (KMS-encrypted, point-in-time recovery on)"
aws dynamodb get-item --table-name "$ATTEMPTS" --consistent-read \
  --key "{\"studentId\":{\"S\":\"$STUDENT\"},\"examId\":{\"S\":\"$EXAM\"}}" \
  --query 'Item.{status:status.S,saves:saves.N,savedAt:savedAt.S,answers:answers.M}' --output json | pj 900
aws dynamodb describe-continuous-backups --table-name "$ATTEMPTS" \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription.PointInTimeRecoveryStatus' --output text | sed 's/^/  PITR: /'

step "5. Browser crashes / laptop restarts -> student opens the exam again"
call GET /exams/$EXAM "$TOKEN" 2>/dev/null | python3 -c '
import json,sys; a=json.load(sys.stdin)["attempt"]
print(f"  same attempt: startedAt={a["startedAt"]} (timer NOT reset)")
print(f"  answers restored: {sorted(a["answers"])}  last save {a["savedAt"]}")'
ok "answers restored from the last autosave"

step "6. Student submits -> 202 Accepted, MCQ marking runs asynchronously (SQS -> marker Lambda)"
call POST /exams/$EXAM/submit "$TOKEN" 2>/dev/null
for _ in $(seq 1 20); do
  st=$(aws dynamodb get-item --table-name "$ATTEMPTS" --key "{\"studentId\":{\"S\":\"$STUDENT\"},\"examId\":{\"S\":\"$EXAM\"}}" --query 'Item.status.S' --output text)
  [ "$st" = MARKED ] && break; sleep 2
done
TT=$(signin tutor1)
call GET /exams/$EXAM/results "$TT" 2>/dev/null | python3 -c '
import json,sys
for r in json.load(sys.stdin)["results"]:
    if r["student_id"]=="'$STUDENT'": print(f"  Aurora results row: {r["student_id"]} scored {r["score"]}/{r["max_score"]} (MCQ) marked_at={r["marked_at"]}")'
ok "attempt status = $st"
