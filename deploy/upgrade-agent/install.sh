#!/usr/bin/env bash
# Install or remove the new-api web upgrade agent on a systemd host.
#
# Usage (as a user with sudo, from anywhere):
#   deploy/upgrade-agent/install.sh install [PROJECT_DIR]
#   deploy/upgrade-agent/install.sh uninstall
#
# PROJECT_DIR defaults to the repository that contains this script. Install
# creates PROJECT_DIR/upgrade-control, renders the units into
# /etc/systemd/system and starts the path unit and heartbeat timer. It does not
# touch docker-compose.yml: mount the control dir into the new-api service and
# set UPGRADE_CONTROL_DIR yourself (see .agents/rules/fork-release.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNITS=(new-api-upgrade-agent.path new-api-upgrade-agent.service
  new-api-upgrade-agent-heartbeat.service new-api-upgrade-agent-heartbeat.timer)
SYSTEMD_DIR=/etc/systemd/system

install_agent() {
  local project_dir control_dir run_user unit
  project_dir="$(cd "${1:-$SCRIPT_DIR/../..}" && pwd)"
  control_dir="$project_dir/upgrade-control"
  run_user="$(stat -c %U "$project_dir")"
  [ -x "$project_dir/docker-upgrade.sh" ] || {
    echo "error: $project_dir/docker-upgrade.sh not found or not executable" >&2
    exit 1
  }
  mkdir -p "$control_dir"
  chmod 0755 "$control_dir"
  chmod +x "$SCRIPT_DIR/new-api-upgrade-agent.sh"
  for unit in "${UNITS[@]}"; do
    sed -e "s#@PROJECT_DIR@#$project_dir#g" -e "s#@CONTROL_DIR@#$control_dir#g" \
      -e "s#@RUN_USER@#$run_user#g" \
      "$SCRIPT_DIR/$unit" | sudo tee "$SYSTEMD_DIR/$unit" >/dev/null
  done
  sudo systemctl daemon-reload
  sudo systemctl enable --now new-api-upgrade-agent.path new-api-upgrade-agent-heartbeat.timer
  sudo systemctl start new-api-upgrade-agent-heartbeat.service
  echo "installed; control dir: $control_dir; agent runs as $run_user"
  cat "$control_dir/agent.json" 2>/dev/null && echo
}

uninstall_agent() {
  local unit
  sudo systemctl disable --now new-api-upgrade-agent.path new-api-upgrade-agent-heartbeat.timer 2>/dev/null || true
  for unit in "${UNITS[@]}"; do
    sudo rm -f "$SYSTEMD_DIR/$unit"
  done
  sudo systemctl daemon-reload
  echo "uninstalled (control dir left in place)"
}

case "${1:-}" in
  install) shift; install_agent "$@" ;;
  uninstall) uninstall_agent ;;
  *) sed -n '2,12p' "$0"; exit 1 ;;
esac
