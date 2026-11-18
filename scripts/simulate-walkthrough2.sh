#!/usr/bin/env bash
# Walkthrough 2 - a student uploads a 40 MB assignment and the tutor is notified.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
BUCKET=$(out SubmissionsBucket); WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mails() { curl -s http://localhost:4566/_aws/ses | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["messages"]))'; }
BEFORE=$(mails)

step "1. student1 signs in and picks a 40 MB PDF"
TOKEN=$(signin student1)
python3 -c "import os; f=open('$WORK/assignment2.pdf','wb'); f.write(b'%PDF-1.7\n'); f.write(os.urandom(40*1024*1024)); f.write(b'\n%%EOF\n')"
SIZE=$(stat -c %s "$WORK/assignment2.pdf"); echo "  file: assignment2.pdf  $SIZE bytes ($((SIZE/1048576)) MB)"

step "2. POST /api/uploads -> exam-api returns a presigned S3 POST (the API never sees the file)"
P=$(call POST /uploads "$TOKEN" "{\"courseId\":\"DSO303\",\"assignmentId\":\"A2\",\"fileName\":\"assignment2.pdf\",\"contentType\":\"application/pdf\",\"size\":$SIZE}")
echo "$P" | python3 -c '
import json,sys,base64; d=json.load(sys.stdin); pol=json.loads(base64.b64decode(d["fields"]["Policy"]))
print("  key       :", d["key"]); print("  upload to :", d["url"]); print("  expires   :", pol["expiration"])
for c in pol["conditions"]:
    if isinstance(c,list): print("  condition :", c)'
KEY=$(echo "$P" | python3 -c 'import json,sys;print(json.load(sys.stdin)["key"])')

step "3. Browser uploads the 40 MB file straight to S3"
ARGS=$(echo "$P" | python3 -c 'import json,sys,shlex;d=json.load(sys.stdin);print(" ".join("-F "+shlex.quote(k+"="+v) for k,v in d["fields"].items()))')
URL=$(echo "$P" | python3 -c 'import json,sys;print(json.load(sys.stdin)["url"])')
eval curl -s -o /dev/null -w "'  S3 responded HTTP %{http_code}: %{size_upload} bytes in %{time_total}s\n'" $ARGS -F "file=@$WORK/assignment2.pdf" "$URL"
aws s3api head-object --bucket "$BUCKET" --key "$KEY" \
  --query '{ContentLength:ContentLength,ContentType:ContentType,ServerSideEncryption:ServerSideEncryption,VersionId:VersionId,Metadata:Metadata}' | pj
ok "40 MB object stored in S3: SSE-KMS encrypted, versioned, tagged with student/course metadata"

step "4. S3 ObjectCreated -> SQS upload-events -> upload-processor Lambda -> Aurora -> SQS notify -> notifier Lambda -> SES"
for _ in $(seq 1 30); do [ "$(mails)" -gt "$BEFORE" ] && break; sleep 2; done
TT=$(signin tutor1)
call GET /submissions "$TT" 2>/dev/null | python3 -c '
import json,sys
for s in json.load(sys.stdin)["submissions"]:
    if s["s3_key"]=="'"$KEY"'": print(f"  Aurora submissions row #{s["id"]}: {s["student_id"]} {s["course_id"]}/{s["assignment_id"]} {int(s["size_bytes"])/1048576:.1f} MB received {s["received_at"]} tutor_notified_at {s["tutor_notified_at"]}")'
echo "  Email captured by SES:"
curl -s http://localhost:4566/_aws/ses | python3 -c '
import json,sys; m=json.load(sys.stdin)["messages"][-1]
print(f"    From   : {m["Source"]}\n    To     : {m["Destination"]["ToAddresses"][0]}\n    Subject: {m["Subject"]}\n    Sent   : {m["Timestamp"]}")
print("    " + m["Body"]["text_part"].replace("\n","\n    "))'
ok "tutor notified ($BEFORE -> $(mails) emails in SES)"

step "5. Guard rails: wrong type and over-size uploads are refused"
call POST /uploads "$TOKEN" '{"fileName":"run.exe","contentType":"application/x-msdownload","size":1000}' 2>&1 | sed 's/^/  .exe  -> /'
head -c 55000000 /dev/zero > "$WORK/too-big.pdf"
P2=$(call POST /uploads "$TOKEN" '{"fileName":"too-big.pdf","contentType":"application/pdf","size":1}' 2>/dev/null)
ARGS2=$(echo "$P2" | python3 -c 'import json,sys,shlex;d=json.load(sys.stdin);print(" ".join("-F "+shlex.quote(k+"="+v) for k,v in d["fields"].items()))')
eval curl -s $ARGS2 -F "file=@$WORK/too-big.pdf" "$URL" | grep -o '<Code>[^<]*</Code><Message>[^<]*' | sed 's/<[^>]*>/ /g; s/^/  55 MB -> S3 refused:/'

step "6. Lifecycle rules on the submissions bucket (records kept 5 years)"
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json | python3 -c '
import json,sys
for r in json.load(sys.stdin)["Rules"]:
    steps = ["STANDARD"] + [x["StorageClass"] + " @ day " + str(x.get("Days", x.get("TransitionInDays"))) for x in r.get("Transitions", [])]
    exp = r.get("Expiration", {}).get("Days")
    if exp: steps.append("DELETE @ day " + str(exp))
    abort = r.get("AbortIncompleteMultipartUpload", {}).get("DaysAfterInitiation")
    desc = ("abort incomplete multipart uploads after " + str(abort) + " days") if abort else " -> ".join(steps)
    print("  " + r["ID"].ljust(26) + desc)'
