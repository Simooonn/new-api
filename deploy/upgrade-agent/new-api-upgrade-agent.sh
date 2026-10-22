#!/usr/bin/env bash
# Host-side upgrade agent for the new-api web "Upgrade" button.
#
# The new-api container never touches docker. The control dir is shared with
# the container in two halves:
#   inbox/   writable by the container; it may only drop request.json there
#   outbox/  mounted read-only; the agent publishes status.json and agent.json
# Everything else (claimed requests, the run log, temp files) stays in a
# host-only state dir. The agent opens container-supplied files without
# following symlinks, validates the request, and runs docker-upgrade.sh with a
# pinned IMAGE_REPO, so a compromised container can at most ask to switch to a
# published fork release.
#
# Usage:
#   new-api-upgrade-agent.sh run         # process inbox/request.json once (path unit)
#   new-api-upgrade-agent.sh heartbeat   # refresh outbox/agent.json (timer)
#
# Environment:
#   PROJECT_DIR   compose project dir that holds docker-upgrade.sh
#                 (default: /home/ubuntu/wmm-code/new-api)
#   CONTROL_DIR   shared control dir (default: $PROJECT_DIR/upgrade-control)
#   STATE_DIR     host-only agent state (default: $PROJECT_DIR/.upgrade/agent)
#   IMAGE_REPO    the only repository upgrades may come from
#                 (default: ghcr.io/simooonn/new-api)
#   UPGRADE_SCRIPT  script to run (default: $PROJECT_DIR/docker-upgrade.sh)
#   STATUS_URL    new-api status endpoint on the host
#                 (default: http://127.0.0.1:3001/api/status)

set -uo pipefail

AGENT_VERSION=1
PROJECT_DIR="${PROJECT_DIR:-/home/ubuntu/wmm-code/new-api}"
CONTROL_DIR="${CONTROL_DIR:-$PROJECT_DIR/upgrade-control}"
STATE_DIR="${STATE_DIR:-$PROJECT_DIR/.upgrade/agent}"
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/simooonn/new-api}"
UPGRADE_SCRIPT="${UPGRADE_SCRIPT:-$PROJECT_DIR/docker-upgrade.sh}"
STATUS_URL="${STATUS_URL:-http://127.0.0.1:3001/api/status}"

INBOX_DIR="$CONTROL_DIR/inbox"
OUTBOX_DIR="$CONTROL_DIR/outbox"
REQUEST_FILE="$INBOX_DIR/request.json"
STATUS_FILE="$OUTBOX_DIR/status.json"
AGENT_FILE="$OUTBOX_DIR/agent.json"
LOG_FILE="$STATE_DIR/last-run.log"
# Must stay identical to systemUpgradeTagPattern in service/system_upgrade.go.
TAG_PATTERN='^v[0-9]+(\.[0-9]+){2,}[0-9A-Za-z.-]*-ace\.[1-9][0-9]*$'
ID_PATTERN='^[0-9a-f]{16}$'
VERSION_PATTERN='^[0-9A-Za-z.+-]{1,64}$'

now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ensure_dirs() {
  mkdir -p "$INBOX_DIR" "$OUTBOX_DIR" "$STATE_DIR"
  chmod 0700 "$STATE_DIR"
}

# write_json FILE key value [key value ...] writes a flat JSON object
# atomically. Temp files live in the host-only state dir and get their mode
# through the open descriptor, so nothing is ever done by path in a directory
# the container can write.
write_json() {
  local file="$1"
  shift
  python3 - "$file" "$STATE_DIR" "$@" <<'PY'
import json, os, sys, tempfile
path, state_dir, items = sys.argv[1], sys.argv[2], sys.argv[3:]
data = dict(zip(items[0::2], items[1::2]))
# requested_by is the numeric id of the administrator who asked.
if "requested_by" in data:
    data["requested_by"] = int(data["requested_by"]) if data["requested_by"].isdigit() else 0
fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".tmp-")
try:
    os.fchmod(fd, 0o644)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    raise
PY
}

set_status() {
  # set_status phase message; a failed write must never abort a running upgrade.
  write_json "$STATUS_FILE" \
    id "$REQUEST_ID" tag "$REQUEST_TAG" phase "$1" message "$2" \
    from_version "$FROM_VERSION" requested_by "$REQUESTED_BY" updated_at "$(now_iso)" ||
    echo "warning: could not write $STATUS_FILE" >&2
}

# claim_request moves inbox/request.json into the host-only state dir without
# following symlinks and prints "id<TAB>tag<TAB>requested_by". Anything that is
# not a small regular JSON file is discarded.
claim_request() {
  python3 - "$INBOX_DIR" "$STATE_DIR" <<'PY'
import json, os, shutil, stat, sys
inbox, state_dir = sys.argv[1], sys.argv[2]
inbox_fd = os.open(inbox, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
claimed = os.path.join(state_dir, "request-%d.json" % os.getpid())
try:
    # rename() never follows a symlink named request.json; it just moves it.
    os.rename("request.json", claimed, src_dir_fd=inbox_fd)
except FileNotFoundError:
    sys.exit(3)
def discard(path):
    # A claimed entry may be a symlink, a directory or a file; never follow it.
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path, ignore_errors=True)
    else:
        os.unlink(path)
info = os.lstat(claimed)
raw = b""
if stat.S_ISREG(info.st_mode):
    fd = os.open(claimed, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        if stat.S_ISREG(os.fstat(fd).st_mode):
            raw = os.read(fd, 4097)
    finally:
        os.close(fd)
discard(claimed)
try:
    data = json.loads(raw) if 0 < len(raw) <= 4096 else {}
except ValueError:
    data = {}
if not isinstance(data, dict):
    data = {}
def field(name):
    value = data.get(name, "")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return ""
    return str(value).replace("\t", " ").replace("\n", " ")[:80]
print("\t".join([field("id"), field("tag"), field("requested_by")]))
PY
}

cmd_heartbeat() {
  ensure_dirs
  write_json "$AGENT_FILE" version "$AGENT_VERSION" image_repo "$IMAGE_REPO" updated_at "$(now_iso)"
}

cmd_run() {
  ensure_dirs
  [ -e "$REQUEST_FILE" ] || [ -L "$REQUEST_FILE" ] || exit 0
  cmd_heartbeat

  local claimed
  claimed="$(claim_request)" || exit 0
  IFS=$'\t' read -r REQUEST_ID REQUEST_TAG REQUESTED_BY <<<"$claimed"
  [[ "$REQUESTED_BY" =~ ^[0-9]{1,10}$ ]] || REQUESTED_BY=""
  FROM_VERSION=""

  if ! [[ "$REQUEST_ID" =~ $ID_PATTERN ]] || ! [[ "$REQUEST_TAG" =~ $TAG_PATTERN ]]; then
    [[ "$REQUEST_ID" =~ $ID_PATTERN ]] || REQUEST_ID=""
    set_status failed "Rejected request: not a fork release tag"
    exit 0
  fi

  FROM_VERSION="$(curl -fsS --max-time 5 "$STATUS_URL" 2>/dev/null |
    python3 -c 'import json,sys
try: print((json.load(sys.stdin).get("data") or {}).get("version") or "")
except Exception: print("")' || true)"
  [[ "$FROM_VERSION" =~ $VERSION_PATTERN ]] || FROM_VERSION=""

  set_status pulling "Pulling $REQUEST_TAG"
  : > "$LOG_FILE"
  # The tag is passed as one argv element; IMAGE_REPO is pinned so the request
  # cannot choose another registry. Script output drives the reported phase.
  local line
  while IFS= read -r line; do
    echo "$line" >> "$LOG_FILE"
    case "$line" in
      *"recreating "*) set_status recreating "Recreating the new-api container" ;;
      *" healthy: "* | *" waiting: "*) set_status health_check "Waiting for the new version to report healthy" ;;
      *"rolling back to "*) set_status rolling_back "Health check failed; switching back to the previous version" ;;
    esac
  done < <(PROJECT_DIR="$PROJECT_DIR" IMAGE_REPO="$IMAGE_REPO" STATUS_URL="$STATUS_URL" \
    CONTROL_DIR="$CONTROL_DIR" "$UPGRADE_SCRIPT" upgrade "$REQUEST_TAG" 2>&1 < /dev/null; echo "__exit=$?")

  if [ "$(tail -1 "$LOG_FILE" | sed -n 's/^__exit=//p')" = "0" ]; then
    set_status succeeded "Upgraded to $REQUEST_TAG"
  else
    local reason
    reason="$(grep -E ' error: ' "$LOG_FILE" | tail -1 | sed -E 's/^.* error: //' | tr -cd '[:print:]' | cut -c1-300)"
    set_status failed "${reason:-Upgrade failed; see the agent log on the host}"
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
    sed -n '2,27p' "$0"
    exit 1
    ;;
esac
