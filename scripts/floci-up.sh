#!/usr/bin/env bash
# Start the local AWS emulator (Floci) used by this project. Idempotent.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export A2_FLOCI_DATA="$ROOT/.floci-data"
mkdir -p "$A2_FLOCI_DATA"
docker info >/dev/null 2>&1 || { echo "Docker is not running" >&2; exit 1; }
docker compose -f "$ROOT/infra/floci/docker-compose.yml" up -d
echo "Waiting for Floci on :4566 ..."
for _ in $(seq 1 90); do
  curl -sf http://localhost:4566/_floci/health >/dev/null && { echo "Floci is healthy"; exit 0; }
  sleep 2
done
docker logs --tail 40 a2-floci >&2; exit 1
