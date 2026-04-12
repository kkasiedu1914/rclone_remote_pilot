#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
ensure_runtime_dirs

SYNC_INCLUDE_GLOBS="${SYNC_INCLUDE_GLOBS:-"results/** outputs/** logs/** *.out *.log *.txt"}"
SYNC_EXCLUDES="${SYNC_EXCLUDES:-".git/** .remote-pilot/** state/** .env .relay.lock **/.relay.lock **/__pycache__/** *.tmp .*.swp"}"

ts() { date -Is; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$SYNC_LOG_FILE"; }

sync_outputs() {
  command -v rclone >/dev/null 2>&1 || { log "rclone not found; skipping mirror"; return 0; }
  require_config_value "PROJECT_DIR"
  require_config_value "RCLONE_REMOTE"
  require_config_value "MIRROR_ROOT_FOLDER_ID"

  local dest="$RCLONE_REMOTE"
  if [[ -n "$MIRROR_REMOTE_SUBDIR" ]]; then
    dest="${dest%/}/${MIRROR_REMOTE_SUBDIR}"
  fi

  local -a cfg_arg=()
  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    cfg_arg=(--config "$RCLONE_CONFIG")
  fi
  local -a extra_args=()
  if [[ -n "${RCLONE_EXTRA_FLAGS:-}" ]]; then
    local split_ifs="$IFS"
    IFS=' '
    read -r -a extra_args <<< "$RCLONE_EXTRA_FLAGS"
    IFS="$split_ifs"
  fi

  local -a filter_args=()
  if [[ -n "$SYNC_EXCLUDES" ]]; then
    local split_ifs="$IFS"
    local -a exclude_patterns=()
    IFS=' '
    read -r -a exclude_patterns <<< "$SYNC_EXCLUDES"
    IFS="$split_ifs"
    local pattern=""
    for pattern in "${exclude_patterns[@]}"; do
      filter_args+=(--filter "- $pattern")
    done
  fi
  if [[ -n "$SYNC_INCLUDE_GLOBS" ]]; then
    local split_ifs="$IFS"
    local -a include_patterns=()
    IFS=' '
    read -r -a include_patterns <<< "$SYNC_INCLUDE_GLOBS"
    IFS="$split_ifs"
    local pattern=""
    for pattern in "${include_patterns[@]}"; do
      filter_args+=(--filter "+ $pattern")
    done
  fi

  log "Ensuring remote directory exists: $dest"
  rclone "${cfg_arg[@]}" mkdir "$dest" \
    --drive-root-folder-id="$MIRROR_ROOT_FOLDER_ID" \
    >> "$SYNC_LOG_FILE" 2>&1 || log "WARN mkdir reported issues"

  log "Mirroring $SYNC_SOURCE_DIR -> $dest"
  rclone "${cfg_arg[@]}" sync "$SYNC_SOURCE_DIR" "$dest" \
    --drive-root-folder-id="$MIRROR_ROOT_FOLDER_ID" \
    --delete-excluded \
    --drive-skip-gdocs \
    "${extra_args[@]}" \
    "${filter_args[@]}" >> "$SYNC_LOG_FILE" 2>&1 || log "WARN rclone sync reported issues"
}

touch "$SYNC_LOG_FILE"
log "=== sync started ==="
sync_outputs
log "=== sync finished ==="
