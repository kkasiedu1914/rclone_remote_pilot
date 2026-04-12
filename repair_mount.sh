#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/mount_utils.sh"

MOUNT_POINT="${COMMAND_CHANNEL_MOUNT:-}"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "COMMAND_CHANNEL_MOUNT is not set" >&2
  exit 1
fi

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" >&2
}

reset_mount_path() {
  local mp="$1"
  [[ -z "$mp" ]] && return 1

  fusermount -uz "$mp" 2>/dev/null || true
  umount -l "$mp" 2>/dev/null || true

  local target_pids=""
  target_pids="$(mount_pids "$mp")"
  if [[ -n "$target_pids" ]]; then
    log "INFO killing process(es) holding $mp: $target_pids"
    kill -9 $target_pids 2>/dev/null || true
    sleep 1
    fusermount -uz "$mp" 2>/dev/null || true
    umount -l "$mp" 2>/dev/null || true
  fi

  rm -rf "$mp" 2>/dev/null || true
  mkdir -p "$mp" 2>/dev/null || {
    log "ERROR failed to recreate mount path $mp"
    return 1
  }
}

reset_mount_path "$MOUNT_POINT"
log "INFO mount path reset: $MOUNT_POINT"
