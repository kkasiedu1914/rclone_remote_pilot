#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

mount_responsive() {
  local mp="$1"
  [[ -z "$mp" ]] && return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout 5s stat "$mp" >/dev/null 2>&1
  else
    stat "$mp" >/dev/null 2>&1
  fi
}

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
