#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
ensure_runtime_dirs

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*"
}

try_unmount() {
  local mount_point="$1"
  [[ -z "$mount_point" ]] && return 0

  if mountpoint -q "$mount_point"; then
    log "Unmounting $mount_point"
    fusermount -u "$mount_point" 2>/dev/null || true
    if mountpoint -q "$mount_point"; then
      fusermount -uz "$mount_point" 2>/dev/null || true
    fi
    if mountpoint -q "$mount_point"; then
      local target_pids=""
      if command -v pgrep >/dev/null 2>&1; then
        target_pids="$(pgrep -f "$mount_point" 2>/dev/null || true)"
      fi
      if [[ -n "$target_pids" ]]; then
        kill -9 $target_pids 2>/dev/null || true
        sleep 1
        fusermount -uz "$mount_point" 2>/dev/null || true
      fi
    fi
  fi

  fusermount -uz "$mount_point" 2>/dev/null || true
  umount -l "$mount_point" 2>/dev/null || true

  if [[ -d "$mount_point" ]]; then
    rmdir "$mount_point" 2>/dev/null || true
  fi
}

stop_relay() {
  if [[ -f "$RELAY_PID_FILE" ]]; then
    local pid=""
    pid="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log "Stopping relay PID $pid"
      kill "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        log "Force killing relay PID $pid"
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$RELAY_PID_FILE"
  fi

  rm -f "$RELAY_LOCK_FILE"
  find "$STATE_DIR" -type f -name '.commands.*.sh' -delete 2>/dev/null || true

  if mountpoint -q "$COMMAND_CHANNEL_MOUNT"; then
    if command -v timeout >/dev/null 2>&1 && timeout 5s stat "$COMMAND_CHANNEL_MOUNT" >/dev/null 2>&1; then
      :
    else
      try_unmount "$COMMAND_CHANNEL_MOUNT"
    fi
  fi
}

start_relay() {
  require_config_value "COMMAND_CHANNEL_MOUNT"
  require_config_value "COMMAND_CHANNEL_FOLDER_ID"
  require_config_value "RCLONE_REMOTE"

  if [[ -f "$RELAY_PID_FILE" ]]; then
    local old_pid=""
    old_pid="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "relay already running (PID $old_pid)" >&2
      exit 1
    fi
    rm -f "$RELAY_PID_FILE" "$RELAY_LOCK_FILE"
  fi

  chmod +x "$SCRIPT_DIR/relay.sh"
  find "$SCRIPT_DIR" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

  nohup bash "$SCRIPT_DIR/relay.sh" > "$RELAY_LOG_FILE" 2>&1 &
  local relay_pid=$!
  echo "$relay_pid" > "$RELAY_PID_FILE"

  sleep 1
  if kill -0 "$relay_pid" 2>/dev/null; then
    log "relay started (PID $relay_pid)"
  else
    echo "relay failed to start; see $RELAY_LOG_FILE" >&2
    tail -n 50 "$RELAY_LOG_FILE" 2>/dev/null || true
    exit 1
  fi
}

status_relay() {
  if [[ -f "$RELAY_PID_FILE" ]]; then
    local pid=""
    pid="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "running pid=$pid"
      exit 0
    fi
  fi
  echo "stopped"
  exit 1
}

case "${1:-start}" in
  start)
    start_relay
    ;;
  stop)
    stop_relay
    ;;
  restart)
    stop_relay
    start_relay
    ;;
  status)
    status_relay
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 1
    ;;
esac
