#!/usr/bin/env bash
# Stop the emulator. State in .floci-data is kept. Add --purge to also wipe it.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Kept outside the repo so a CI checkout (git clean) can never delete it while Floci runs.
export A2_FLOCI_DATA="${A2_FLOCI_DATA:-$HOME/.a2-floci-data}"
docker compose -f "$ROOT/infra/floci/docker-compose.yml" down
# Floci starts Lambda/Aurora containers itself; remove them too.
docker ps -aq --filter "name=^a2-" | xargs -r docker rm -f >/dev/null
if [ "${1:-}" = "--purge" ]; then
  docker run --rm -v "$A2_FLOCI_DATA":/d alpine sh -c 'rm -rf /d/* /d/.[!.]*' && echo "State wiped"
fi
