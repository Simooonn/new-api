#!/usr/bin/env bash
# Tests for new-api-upgrade-agent.sh against a fake docker-upgrade.sh.
# Run: deploy/upgrade-agent/agent_test.sh

set -uo pipefail

AGENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/new-api-upgrade-agent.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0
ID=0123456789abcdef

# Fake upgrade script: records its argv, prints docker-upgrade.sh-style lines.
cat > "$WORK/fake-upgrade.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CALLS_FILE"
echo "IMAGE_REPO=$IMAGE_REPO" >> "$CALLS_FILE"
echo "2026-10-22 10:00:00 pulling $IMAGE_REPO:$2"
# docker-upgrade.sh logs the version the old container reports.
printf '2026-10-22 10:00:01 current image pinned (version %s)\n' "${FAKE_VERSION_LINE:-v1}"
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

reset_control() {
  rm -rf "$WORK/control" "$WORK/state" "$WORK/calls"
  mkdir -p "$WORK/control/inbox" "$WORK/control/outbox"
}

write_request() {
  # write_request TAG [ID]
  python3 -c 'import json,sys; json.dump({"id": sys.argv[3], "tag": sys.argv[1], "requested_by": 7}, open(sys.argv[2], "w"))' \
    "$1" "$WORK/control/inbox/request.json" "${2:-$ID}"
}

agent() {
  CALLS_FILE="$WORK/calls" PROJECT_DIR="$WORK" CONTROL_DIR="$WORK/control" STATE_DIR="$WORK/state" \
    UPGRADE_SCRIPT="$WORK/fake-upgrade.sh" STATUS_URL="http://127.0.0.1:9/none" \
    "$AGENT" "$@"
}

run_agent() {
  # run_agent TAG [ID] -> leaves status in outbox/status.json
  reset_control
  write_request "$@"
  agent run
}

field() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$WORK/control/outbox/status.json" "$1"
}

called() {
  [ -e "$WORK/calls" ] && echo called || echo skipped
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
check "valid tag keeps request id" "$(field id)" "$ID"
check "requester carried into status" "$(field requested_by)" "7"
check "tag passed as a single argument" "$(sed -n 2p "$WORK/calls")" "v1.0.0-rc.44-ace.3"
check "image repo pinned" "$(grep IMAGE_REPO "$WORK/calls")" "IMAGE_REPO=ghcr.io/simooonn/new-api"
check "request consumed" "$([ -e "$WORK/control/inbox/request.json" ] && echo present || echo gone)" "gone"
check "heartbeat written to outbox" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$WORK/control/outbox/agent.json")" "1"
check "run log kept out of the shared dir" "$([ -f "$WORK/state/last-run.log" ] && ! [ -e "$WORK/control/last-run.log" ] && echo host-only || echo shared)" "host-only"
check "no temp files left in shared dirs" "$(find "$WORK/control" -name '.tmp-*' | wc -l | tr -d ' ')" "0"

FAKE_FAIL=1 run_agent "v1.0.0-rc.44-ace.4"
check "failed upgrade reported" "$(field phase)" "failed"
check "failure reason from script" "$(field message)" "upgrade to ghcr.io/simooonn/new-api:v1.0.0-rc.44-ace.4 failed and was rolled back to new-api:rollback-1"

for tag in "v1.0.0-rc.44" "evil.example.com/new-api:v1.0.0-ace.1" 'v1.0.0-ace.1;touch /tmp/pwned' "v1.0.0-ace.0" "../v1.0.0-ace.1" ""; do
  run_agent "$tag"
  check "rejects tag '$tag'" "$(field phase)" "failed"
  check "script not run for '$tag'" "$(called)" "skipped"
done

run_agent "v1.0.0-rc.44-ace.3" "$(printf 'x%.0s' $(seq 1 5000))"
check "rejects an oversized id" "$(field phase)" "failed"
check "script not run for an oversized id" "$(called)" "skipped"

# Symlink attacks: the container controls the inbox and could place links.
reset_control
echo "secret: keep me" > "$WORK/victim"
ln -s "$WORK/victim" "$WORK/control/inbox/request.json"
agent run
check "request.json symlink is not followed" "$(cat "$WORK/victim")" "secret: keep me"
check "request.json symlink rejected without running" "$(called)" "skipped"
check "request.json symlink removed from inbox" "$([ -L "$WORK/control/inbox/request.json" ] && echo present || echo gone)" "gone"

reset_control
mkdir -p "$WORK/control/inbox/request.json"
agent run
check "a directory named request.json is not run" "$(called)" "skipped"

reset_control
echo "do not truncate" > "$WORK/victim"
ln -s "$WORK/victim" "$WORK/control/last-run.log"
write_request "v1.0.0-rc.44-ace.3"
FAKE_VERSION_LINE=$'v1\nssh-ed25519 AAAA attacker' agent run
check "old last-run.log link is never written" "$(cat "$WORK/victim")" "do not truncate"

reset_control
agent heartbeat
check "heartbeat creates no shared temp files" "$(find "$WORK/control" -name '.tmp-*' | wc -l | tr -d ' ')" "0"

reset_control
agent run
check "no request is a no-op" "$([ -e "$WORK/control/outbox/status.json" ] && echo written || echo none)" "none"

exit $FAILED
