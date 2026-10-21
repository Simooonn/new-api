#!/usr/bin/env bash
# Upgrade or roll back the new-api container to a published image.
# Only the new-api service is recreated; postgres, redis and other services
# are left running. The image is pinned in docker-compose.override.yml, which
# compose also loads automatically, so the hand-edited docker-compose.yml is
# never rewritten and a manual `docker compose up -d` keeps the same image.
#
# Usage (run from the compose project directory, or set PROJECT_DIR):
#   ./docker-upgrade.sh upgrade <image|tag>   # e.g. v1.0.0-rc.44-ace.2
#   ./docker-upgrade.sh rollback [image]      # default: previous image
#   ./docker-upgrade.sh status
#
# Upgrade steps: pull -> pin the current image under a rollback tag ->
# recreate new-api -> wait for /api/status to report the expected version.
# A failed health check switches back automatically.
#
# Schema changes are additive between adjacent releases, so rollback only
# switches the image and never restores the database. The optional pg_dump is
# a disaster-recovery copy, not a rollback step: restoring it would discard
# everything written after the upgrade.
#
# Environment:
#   PROJECT_DIR      compose project dir (default: current directory)
#   IMAGE_REPO       repo used when a bare tag is given (default: ghcr.io/simooonn/new-api)
#   SERVICE          compose service (default: new-api)
#   PG_CONTAINER     postgres container (default: postgres)
#   PG_USER, PG_DB   pg_dump target (default: root / new-api)
#   STATUS_URL       health endpoint (default: http://127.0.0.1:3001/api/status)
#   HEALTH_TIMEOUT   seconds to wait for health (default: 180)
#   BACKUP=1         take a pg_dump before upgrading (default: off)
#   KEEP_BACKUPS     number of dumps kept in .upgrade/backups (default: 5)
#   DOCKER           docker command (default: "docker", or "sudo -n docker"
#                    when the socket is not accessible)

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/simooonn/new-api}"
SERVICE="${SERVICE:-new-api}"
PG_CONTAINER="${PG_CONTAINER:-postgres}"
PG_USER="${PG_USER:-root}"
PG_DB="${PG_DB:-new-api}"
STATUS_URL="${STATUS_URL:-http://127.0.0.1:3001/api/status}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
KEEP_BACKUPS="${KEEP_BACKUPS:-5}"

STATE_DIR="$PROJECT_DIR/.upgrade"
BACKUP_DIR="$STATE_DIR/backups"
OVERRIDE_FILE="$PROJECT_DIR/docker-compose.override.yml"
HISTORY_LOG="$STATE_DIR/history.log"

if [ -z "${DOCKER:-}" ]; then
  if docker info >/dev/null 2>&1; then
    DOCKER="docker"
  else
    DOCKER="sudo -n docker"
  fi
fi

ensure_state_dir() {
  # Keep dumps and state out of git when the project dir is a checkout.
  if [ ! -d "$STATE_DIR" ]; then
    mkdir -p "$STATE_DIR"
    echo "*" > "$STATE_DIR/.gitignore"
  fi
}

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line"
  ensure_state_dir
  echo "$line" >> "$HISTORY_LOG"
}

die() {
  log "error: $*"
  exit 1
}

usage() {
  sed -n '2,33p' "$0"
}

compose() {
  local files=(-f "$PROJECT_DIR/docker-compose.yml")
  [ -f "$OVERRIDE_FILE" ] && files+=(-f "$OVERRIDE_FILE")
  $DOCKER compose --project-directory "$PROJECT_DIR" "${files[@]}" "$@"
}

resolve_image() {
  case "$1" in
    */*|*:*) echo "$1" ;;
    *) echo "$IMAGE_REPO:$1" ;;
  esac
}

expected_version() {
  local image="$1"
  case "$image" in
    *@*) echo "" ;;
    *:*)
      local tag="${image##*:}"
      if [[ "$tag" == v[0-9]* ]]; then echo "$tag"; else echo ""; fi
      ;;
    *) echo "" ;;
  esac
}

service_container() {
  compose ps -q "$SERVICE" 2>/dev/null | head -1
}

running_image() {
  local id
  id="$(service_container)"
  [ -n "$id" ] && $DOCKER inspect "$id" --format '{{.Config.Image}}' 2>/dev/null || true
}

running_image_id() {
  local id
  id="$(service_container)"
  [ -n "$id" ] && $DOCKER inspect "$id" --format '{{.Image}}' 2>/dev/null || true
}

reported_version() {
  # /api/status is JSON; extract data.version without requiring jq.
  curl -fsS --max-time 5 "$STATUS_URL" 2>/dev/null |
    python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get("success") is not True:
    sys.exit(1)
print((d.get("data") or {}).get("version") or "")'
}

write_override() {
  local image="$1"
  cat > "$OVERRIDE_FILE" <<EOF
# Managed by docker-upgrade.sh. Pins the image of the $SERVICE service.
services:
  $SERVICE:
    image: $image
EOF
}

wait_healthy() {
  local version="$1" deadline reported
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if reported="$(reported_version)"; then
      if [ -z "$version" ] || [ "$reported" = "$version" ]; then
        log "healthy: version='${reported}'"
        return 0
      fi
      log "waiting: reported version '${reported}', expected '${version}'"
    fi
    sleep 3
  done
  return 1
}

switch_to() {
  local image="$1" version="$2"
  write_override "$image"
  log "recreating $SERVICE with $image"
  compose up -d --no-deps --no-build --force-recreate "$SERVICE" || return 1
  wait_healthy "$version"
}

backup_database() {
  local file
  mkdir -p "$BACKUP_DIR"
  file="$BACKUP_DIR/$PG_DB-$(date '+%Y%m%d-%H%M%S').dump"
  log "backing up database to $file"
  $DOCKER exec "$PG_CONTAINER" pg_dump -U "$PG_USER" -Fc "$PG_DB" > "$file" || {
    rm -f "$file"
    die "pg_dump failed; nothing was changed"
  }
  [ -s "$file" ] || { rm -f "$file"; die "backup file is empty; nothing was changed"; }
  log "backup size: $(du -h "$file" | cut -f1)"
  ls -t "$BACKUP_DIR"/*.dump | tail -n +"$((KEEP_BACKUPS + 1))" | xargs -r rm -f
}

cmd_upgrade() {
  local target current_id rollback_tag current_version
  [ $# -eq 1 ] || die "upgrade needs exactly one image or tag"
  target="$(resolve_image "$1")"

  current_id="$(running_image_id)"
  [ -n "$current_id" ] || die "service '$SERVICE' has no running container"
  current_version="$(reported_version || true)"

  if [ "${BACKUP:-0}" = "1" ]; then
    backup_database
  fi

  log "pulling $target"
  $DOCKER pull "$target" >/dev/null || die "pull failed; nothing was changed"

  # Pin the exact image that is running now, even if its tag is reused later.
  rollback_tag="new-api:rollback-$(date '+%Y%m%d-%H%M%S')"
  $DOCKER tag "$current_id" "$rollback_tag"
  echo "$rollback_tag" > "$STATE_DIR/previous-image"
  echo "$current_version" > "$STATE_DIR/previous-version"
  log "current image pinned as $rollback_tag (was $(running_image), version '${current_version}')"

  if switch_to "$target" "$(expected_version "$target")"; then
    echo "$target" > "$STATE_DIR/current-image"
    log "upgrade finished: $target"
    return 0
  fi

  log "health check failed for $target; last logs:"
  $DOCKER logs --tail 50 "$(service_container)" 2>&1 | tee -a "$HISTORY_LOG" || true
  log "rolling back to $rollback_tag"
  if switch_to "$rollback_tag" "$current_version"; then
    die "upgrade to $target failed and was rolled back to $rollback_tag"
  fi
  die "upgrade failed and rollback did not become healthy; check '$SERVICE' manually"
}

cmd_rollback() {
  local target version
  if [ $# -ge 1 ]; then
    target="$(resolve_image "$1")"
    version="$(expected_version "$target")"
  else
    [ -f "$STATE_DIR/previous-image" ] || die "no previous image recorded"
    target="$(cat "$STATE_DIR/previous-image")"
    version="$(cat "$STATE_DIR/previous-version" 2>/dev/null || true)"
  fi
  $DOCKER image inspect "$target" >/dev/null 2>&1 || die "image not found locally: $target"
  log "rolling back to $target (database is not restored)"
  switch_to "$target" "$version" ||
    die "rollback target did not become healthy"
  echo "$target" > "$STATE_DIR/current-image"
  log "rollback finished: $target"
}

cmd_status() {
  echo "container image: $(running_image)"
  echo "reported version: $(reported_version || echo '<unavailable>')"
  [ -f "$OVERRIDE_FILE" ] && echo "override: $(grep 'image:' "$OVERRIDE_FILE" | tr -d ' ')"
  [ -f "$STATE_DIR/previous-image" ] &&
    echo "previous image: $(cat "$STATE_DIR/previous-image") ($(cat "$STATE_DIR/previous-version" 2>/dev/null))"
  if [ -d "$BACKUP_DIR" ]; then
    echo "latest backup: $(ls -t "$BACKUP_DIR" 2>/dev/null | head -1)"
  fi
}

[ -f "$PROJECT_DIR/docker-compose.yml" ] || die "docker-compose.yml not found in $PROJECT_DIR"
# The override would otherwise define a brand-new service with this name.
$DOCKER compose --project-directory "$PROJECT_DIR" -f "$PROJECT_DIR/docker-compose.yml" config --services |
  grep -qx "$SERVICE" || die "service '$SERVICE' is not defined in docker-compose.yml"

case "${1:-}" in
  upgrade) shift; cmd_upgrade "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  status) cmd_status ;;
  -h|--help|"") usage ;;
  *) usage; exit 1 ;;
esac
