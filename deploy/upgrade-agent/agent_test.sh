#!/usr/bin/env bash
# Tests for new-api-upgrade-agent.sh against a fake docker-upgrade.sh.
# Run: deploy/upgrade-agent/agent_test.sh

set -uo pipefail

AGENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/new-api-upgrade-agent.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

# Fake upgrade script: records its argv, prints docker-upgrade.sh-style lines.
cat > "$WORK/fake-upgrade.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALLS_FILE"
echo "IMAGE_REPO=$IMAGE_REPO" >> "$CALLS_FILE"
echo "2026-10-22 10:00:00 pulling $IMAGE_REPO:$2"
echo "2026-10-22 10:00:01 recreating new-api with $IMAGE_REPO:$2"
if [ "${FAKE_FAIL:-0}" = 1 ]; then
  echo "2026-10-22 10:00:05 rolling back to new-api:rollback-1"
  echo "2026-10-22 10:00:06 error: upgrade to $IMAGE_REPO:$2 failed and was rolled back to new-api:rollback-1"
  exit 1
fi
echo "2026-10-22 10:00:02 healthy: version='$2'"
echo "2026-10-22 10:00:02 upgrade finished: $IMAGE_REPO:$2"
EOF
chmod +x "$WORK/fake-upgrade.sh"

run_agent() {
  # run_agent TAG -> leaves status in $WORK/control/status.json
  rm -rf "$WORK/control" "$WORK/calls"
  mkdir -p "$WORK/control"
  python3 -c 'import json,sys; json.dump({"id": "req-1", "tag": sys.argv[1], "requested_by": 7}, open(sys.argv[2], "w"))' \
    "$1" "$WORK/control/request.json"
  CALLS_FILE="$WORK/calls" PROJECT_DIR="$WORK" CONTROL_DIR="$WORK/control" \
    UPGRADE_SCRIPT="$WORK/fake-upgrade.sh" STATUS_URL="http://127.0.0.1:9/none" \
    "$AGENT" run
}

field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$WORK/control/status.json" "$1"
}

check() {
  # check DESCRIPTION ACTUAL EXPECTED
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: got '$2', want '$3'"
    FAILED=1
  fi
}

run_agent "v1.0.0-rc.44-ace.3"
check "valid tag succeeds" "$(field phase)" "succeeded"
check "valid tag keeps request id" "$(field id)" "req-1"
check "requester carried into status" "$(field requested_by)" "7"
check "tag passed as a single argument" "$(sed -n 2p "$WORK/calls")" "v1.0.0-rc.44-ace.3"
check "image repo pinned" "$(grep IMAGE_REPO "$WORK/calls")" "IMAGE_REPO=ghcr.io/simooonn/new-api"
check "request consumed" "$([ -e "$WORK/control/request.json" ] && echo present || echo gone)" "gone"
check "heartbeat written" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/control/agent.json")" "1"

FAKE_FAIL=1 run_agent "v1.0.0-rc.44-ace.4"
check "failed upgrade reported" "$(field phase)" "failed"
check "failure reason from script" "$(field message)" "upgrade to ghcr.io/simooonn/new-api:v1.0.0-rc.44-ace.4 failed and was rolled back to new-api:rollback-1"

for tag in "v1.0.0-rc.44" "evil.example.com/new-api:v1.0.0-ace.1" 'v1.0.0-ace.1;touch /tmp/pwned' "v1.0.0-ace.0" "../v1.0.0-ace.1" ""; do
  run_agent "$tag"
  check "rejects tag '$tag'" "$(field phase)" "failed"
  check "script not run for '$tag'" "$([ -e "$WORK/calls" ] && echo called || echo skipped)" "skipped"
done

rm -rf "$WORK/control"; mkdir -p "$WORK/control"
PROJECT_DIR="$WORK" CONTROL_DIR="$WORK/control" UPGRADE_SCRIPT="$WORK/fake-upgrade.sh" "$AGENT" run
check "no request is a no-op" "$([ -e "$WORK/control/status.json" ] && echo written || echo none)" "none"

exit $FAILED
