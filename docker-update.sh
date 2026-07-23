#!/usr/bin/env bash
# Recreate the running service with the already-built image.
# Does NOT build. Run ./docker-build.sh first when code changes.
#
# Usage:
#   ./docker-update.sh
#   COMPOSE_FILE=docker-compose.yml SERVICE=new-api ./docker-update.sh
#
# Production compose only needs the image name (no build:):
#   services:
#     new-api:
#       image: new-api:ace

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICE="${SERVICE:-new-api}"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not in PATH" >&2
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "error: compose file not found: $COMPOSE_FILE" >&2
  exit 1
fi

echo "==> Recreating service '${SERVICE}' with current image (no build)"
echo "    compose: ${COMPOSE_FILE}"
# --no-build: never compile on start
# --force-recreate: replace container even if config looks unchanged
# --remove-orphans: clean leftover containers from old compose files
docker compose -f "$COMPOSE_FILE" up -d --no-build --force-recreate --remove-orphans "$SERVICE"

echo "==> Update finished."
docker compose -f "$COMPOSE_FILE" ps "$SERVICE"
