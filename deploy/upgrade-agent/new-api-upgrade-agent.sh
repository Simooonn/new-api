#!/usr/bin/env bash
# Host-side upgrade agent for the new-api web "Upgrade" button.
#
# The new-api container never touches docker. It writes a request into a
# control directory that is bind-mounted into the container; this agent runs
# on the host (systemd path unit), validates the request and calls
# docker-upgrade.sh. Progress goes back through status.json in the same
# directory. A compromised container can therefore only ask to switch to a
# published fork release of IMAGE_REPO.
#
# Usage:
#   new-api-upgrade-agent.sh run         # process request.json once (path unit)
#   new-api-upgrade-agent.sh heartbeat   # refresh agent.json (timer)
#
# Environment:
#   PROJECT_DIR   compose project dir that holds docker-upgrade.sh
#                 (default: /home/ubuntu/wmm-code/new-api)
#   CONTROL_DIR   shared control dir (default: $PROJECT_DIR/upgrade-control)
#   IMAGE_REPO    the only repository upgrades may come from
#                 (default: ghcr.io/simooonn/new-api)
#   UPGRADE_SCRIPT  script to run (default: $PROJECT_DIR/docker-upgrade.sh)
#   STATUS_URL    new-api status endpoint on the host
#                 (default: http://127.0.0.1:3001/api/status)

set -euo pipefail

AGENT_VERSION=1
PROJECT_DIR="${PROJECT_DIR:-/home/ubuntu/wmm-code/new-api}"
CONTROL_DIR="${CONTROL_DIR:-$PROJECT_DIR/upgrade-control}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/simooonn/new-api}"
UPGRADE_SCRIPT="${UPGRADE_SCRIPT:-$PROJECT_DIR/docker-upgrade.sh}"
STATUS_URL="${STATUS_URL:-http://127.0.0.1:3001/api/status}"

REQUEST_FILE="$CONTROL_DIR/request.json"
STATUS_FILE="$CONTROL_DIR/status.json"
AGENT_FILE="$CONTROL_DIR/agent.json"
LOG_FILE="$CONTROL_DIR/last-run.log"
TAG_PATTERN='^v[0-9]+(\.[0-9]+){2,}[0-9A-Za-z.-]*-ace\.[1-9][0-9]*$'

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# write_json FILE key value [key value ...] writes a flat JSON object atomically.
write_json() {
  local file="$1"
  shift
  python3 - "$file" "$@" <<'PY'
import json, os, sys, tempfile
path, items = sys.argv[1], sys.argv[2:]
data = dict(zip(items[0::2], items[1::2]))
# requested_by is the numeric id of the administrator who asked.
if "requested_by" in data:
    data["requested_by"] = int(data["requested_by"]) if data["requested_by"].isdigit() else 0
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-")
with os.fdopen(fd, "w") as f:
    json.dump(data, f)
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
}

set_status() {
  # set_status phase message
  write_json "$STATUS_FILE" \
    id "$REQUEST_ID" tag "$REQUEST_TAG" phase "$1" message "$2" \
    from_version "$FROM_VERSION" requested_by "$REQUESTED_BY" updated_at "$(now_iso)"
}

read_request_field() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        value = json.load(f).get(sys.argv[2], "")
except Exception:
    value = ""
print(value if isinstance(value, (str, int)) and not isinstance(value, bool) else "")
PY
}

cmd_heartbeat() {
  mkdir -p "$CONTROL_DIR"
  write_json "$AGENT_FILE" version "$AGENT_VERSION" image_repo "$IMAGE_REPO" updated_at "$(now_iso)"
}

cmd_run() {
  [ -f "$REQUEST_FILE" ] || exit 0
  cmd_heartbeat

  # Claim the request so it runs exactly once, even if the path unit fires again.
  local claimed="$CONTROL_DIR/.request-$$.json"
  mv "$REQUEST_FILE" "$claimed" 2>/dev/null || exit 0
  REQUEST_ID="$(read_request_field "$claimed" id)"
  REQUEST_TAG="$(read_request_field "$claimed" tag)"
  REQUESTED_BY="$(read_request_field "$claimed" requested_by)"
  rm -f "$claimed"
  FROM_VERSION=""

  if ! [[ "$REQUEST_TAG" =~ $TAG_PATTERN ]]; then
    REQUEST_TAG="${REQUEST_TAG:0:80}"
    set_status failed "Rejected tag: not a fork release tag"
    exit 0
  fi

  FROM_VERSION="$(curl -fsS --max-time 5 "$STATUS_URL" 2>/dev/null |
    python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("data") or {}).get("version") or "")
except Exception: print("")' || true)"

  set_status pulling "Pulling $REQUEST_TAG"
  : > "$LOG_FILE"
  # The tag is passed as one argv element; IMAGE_REPO is pinned so the request
  # cannot choose another registry. Script output drives the reported phase.
  local line result=0
  while IFS= read -r line; do
    echo "$line" >> "$LOG_FILE"
    case "$line" in
      *"recreating "*) set_status recreating "Recreating the new-api container" ;;
      *" healthy: "* | *" waiting: "*) set_status health_check "Waiting for the new version to report healthy" ;;
      *"rolling back to "*) set_status rolling_back "Health check failed; switching back to the previous version" ;;
    esac
  done < <(PROJECT_DIR="$PROJECT_DIR" IMAGE_REPO="$IMAGE_REPO" STATUS_URL="$STATUS_URL" \
    "$UPGRADE_SCRIPT" upgrade "$REQUEST_TAG" 2>&1 < /dev/null; echo "__exit=$?")
  result="$(tail -1 "$LOG_FILE" | sed -n 's/^__exit=//p')"

  if [ "$result" = "0" ]; then
    set_status succeeded "Upgraded to $REQUEST_TAG"
  else
    local reason
    reason="$(grep -E ' error: ' "$LOG_FILE" | tail -1 | sed -E 's/^.* error: //' | cut -c1-300)"
    set_status failed "${reason:-Upgrade failed; see last-run.log on the host}"
  fi
  cmd_heartbeat
}

REQUEST_ID=""
REQUEST_TAG=""
REQUESTED_BY=""
FROM_VERSION=""

case "${1:-}" in
  run) cmd_run ;;
  heartbeat) cmd_heartbeat ;;
  *)
    sed -n '2,21p' "$0"
    exit 1
    ;;
esac
