#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"

MOUNT_POINT="${COMMAND_CHANNEL_MOUNT:-}"
if [[ -z "$MOUNT_POINT" ]]; then
  echo "COMMAND_CHANNEL_MOUNT is not set" >&2
  exit 1
fi

mount_pids() {
  local mp="$1"
  [[ -z "$mp" ]] && return 1
  if [[ "${USE_FUSER:-0}" == "1" ]]; then
    if command -v fuser >/dev/null 2>&1; then
      fuser -m "$mp" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true
      return 0
    elif command -v lsof >/dev/null 2>&1; then
      lsof -t +f -- "$mp" 2>/dev/null || true
      return 0
    fi
  fi
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -f "$mp" 2>/dev/null || true
  fi
}

fusermount -uz "$MOUNT_POINT" 2>/dev/null || true
umount -l "$MOUNT_POINT" 2>/dev/null || true

if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$MOUNT_POINT"; then
  target_pids="$(mount_pids "$MOUNT_POINT")"
  if [[ -n "$target_pids" ]]; then
    echo "INFO: killing process(es) holding $MOUNT_POINT: $target_pids" >&2
    kill -9 $target_pids 2>/dev/null || true
    sleep 1
    fusermount -uz "$MOUNT_POINT" 2>/dev/null || true
    umount -l "$MOUNT_POINT" 2>/dev/null || true
  fi
fi
