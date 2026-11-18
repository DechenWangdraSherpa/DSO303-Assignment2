#!/usr/bin/env bash
# Post-deploy checks run by the pipeline. Fails (exit 1) if any check fails.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$ROOT/scripts/lib-env.sh"
fail=0
check() { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected $3, got $2"; fail=1; fi; }
code() { curl -s -m 120 -o /dev/null -w '%{http_code}' "$@"; }
check "API health endpoint" "$(code "$API/health")" 200
check "protected route without a token is refused" "$(code "$API/exams")" 401
T=$(signin student1)
check "student can list exams" "$(code "$API/exams" -H "authorization: Bearer $T")" 200
check "student cannot use tutor routes" "$(code "$API/submissions" -H "authorization: Bearer $T")" 403
TT=$(signin tutor1)
check "tutor can read submissions from Aurora" "$(code "$API/submissions" -H "authorization: Bearer $TT")" 200
check "frontend is published" "$(code "http://localhost:4566/$(out FrontendBucket)/index.html")" 200
exit $fail
