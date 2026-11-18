#!/usr/bin/env bash
# Post-deploy checks run by the pipeline. Fails (exit 1) if any check fails.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
fail=0
code() { curl -s -m 120 -o /dev/null -w '%{http_code}' "$@"; }
# check <name> <expected> <curl args...>
# Each check gets up to 3 tries, 10 s apart: right after a deploy the first call to each
# Lambda is a cold start (and may open the first database connection).
check() {
  local name=$1 want=$2 got; shift 2
  for try in 1 2 3; do
    got=$(code "$@")
    [ "$got" = "$want" ] && { ok "$name ($got)"; return; }
    [ $try -lt 3 ] && sleep 10
  done
  bad "$name: expected $want, got $got"; fail=1
}
check "API health endpoint" 200 "$API/health"
check "protected route without a token is refused" 401 "$API/exams"
T=$(signin student1)
check "student can list exams" 200 "$API/exams" -H "authorization: Bearer $T"
check "student cannot use tutor routes" 403 "$API/submissions" -H "authorization: Bearer $T"
TT=$(signin tutor1)
check "tutor can read submissions from Aurora" 200 "$API/submissions" -H "authorization: Bearer $TT"
check "frontend is published" 200 "http://localhost:4566/$(out FrontendBucket)/index.html"
exit $fail
