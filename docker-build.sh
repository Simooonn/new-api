#!/usr/bin/env bash
# Build the new-api image only. Does not start or restart running containers.
#
# Usage:
#   ./docker-build.sh
#   IMAGE=new-api:ace ./docker-build.sh
#   ./docker-build.sh --no-cache
#
# Production compose only needs the image name (no build:):
#   services:
#     new-api:
#       image: new-api:ace

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

IMAGE="${IMAGE:-new-api:ace}"
DOCKERFILE="${DOCKERFILE:-Dockerfile}"
EXTRA_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --no-cache) EXTRA_ARGS+=(--no-cache) ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--no-cache]" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not in PATH" >&2
  exit 1
fi

if [ ! -f "$DOCKERFILE" ]; then
  echo "error: Dockerfile not found: $DOCKERFILE" >&2
  exit 1
fi

echo "==> Building image '${IMAGE}' from ${DOCKERFILE}"
echo "    Running containers will not be restarted."
docker build "${EXTRA_ARGS[@]}" -f "$DOCKERFILE" -t "$IMAGE" .

echo "==> Build finished."
docker image ls "$IMAGE"
