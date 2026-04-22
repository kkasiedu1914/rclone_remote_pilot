#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"

MOUNT_UTILS="$SCRIPT_DIR/mount_utils.sh"
if [[ -f "$MOUNT_UTILS" ]]; then
  # shellcheck source=/dev/null
  . "$MOUNT_UTILS"
else
  mount_responsive() {
    local mp="$1"
    [[ -z "$mp" ]] && return 1
    if command -v timeout >/dev/null 2>&1; then
      timeout 5s stat "$mp" >/dev/null 2>&1
    else
      stat "$mp" >/dev/null 2>&1
    fi
  }
fi

WRITE_COMMAND_HISTORY="${WRITE_COMMAND_HISTORY:-1}"
INCLUDE_COMMAND_SNAPSHOT_IN_CMD_LOG="${INCLUDE_COMMAND_SNAPSHOT_IN_CMD_LOG:-0}"
COMMAND_SCRIPT_IN="$COMMAND_CHANNEL_MOUNT/$COMMAND_FILE_NAME"
END_TS=0
SHOULD_EXIT=0

ts() { date -Is; }
log() { printf '[%s] %s\n' "$(ts)" "$*" >> "$RELAY_LOG_FILE"; }
cmdlog() { printf '[%s] %s\n' "$(ts)" "$*" >> "$COMMAND_OUTPUT_LOG_FILE"; }

reset_mountpoint_path() {
  local mount_point="$1"
  [[ -z "$mount_point" ]] && return 1

  fusermount -uz "$mount_point" 2>/dev/null || true
  umount -l "$mount_point" 2>/dev/null || true
  rm -rf "$mount_point" 2>/dev/null || true
  mkdir -p "$mount_point" 2>/dev/null || {
    log "ERROR: failed to recreate mount path $mount_point"
    return 1
  }
}

ensure_exec() {
  find "$REMOTE_PILOT_HOME" -maxdepth 1 -type f -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
}

publish_logs() {
  [[ "$PUBLISH_LOGS" == "1" ]] || return 0
  mkdir -p "$COMMAND_CHANNEL_LOG_DIR" 2>/dev/null || {
    log "WARN: could not create COMMAND_CHANNEL_LOG_DIR=$COMMAND_CHANNEL_LOG_DIR"
    return 0
  }

  local file=""
  local base=""
  local tmp=""
  local -a publish_files=(
    "$COMMAND_OUTPUT_LOG_FILE"
    "$RELAY_LOG_FILE"
    "$COMMAND_HISTORY_FILE"
    "$SYNC_LOG_FILE"
    "$SUPERVISOR_LOG_FILE"
    "$EMAIL_LOG_FILE"
  )

  for file in "${publish_files[@]}"; do
    [[ -f "$file" ]] || continue
    base="$(basename "$file")"
    tmp="$COMMAND_CHANNEL_LOG_DIR/.${base}.$$.tmp"
    cp -f "$file" "$tmp" 2>/dev/null && mv -f "$tmp" "$COMMAND_CHANNEL_LOG_DIR/$base" 2>/dev/null || {
      rm -f "$tmp" 2>/dev/null || true
      log "WARN: failed to publish $file -> $COMMAND_CHANNEL_LOG_DIR/$base"
    }
  done
}

log_missing_command_script() {
  log "WARN: command file is missing on the mounted channel; create it from the shared Drive folder before expecting commands to run: $COMMAND_SCRIPT_IN"
}

append_to_history() {
  local script_path="$1"
  [[ "$WRITE_COMMAND_HISTORY" == "1" ]] || return 0
  [[ -s "$script_path" ]] || return 0
  {
    echo "=== $(ts) ==="
    cat "$script_path"
    echo
  } >> "$COMMAND_HISTORY_FILE"
}

prune_pids() {
  shopt -s nullglob
  local pid_file=""
  local pid=""
  for pid_file in "$PIDS_DIR"/*.pid; do
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$pid_file" 2>/dev/null || true
    fi
  done
  shopt -u nullglob
}

count_running_jobs() {
  prune_pids
  shopt -s nullglob
  local -a pid_files=("$PIDS_DIR"/*.pid)
  shopt -u nullglob
  echo "${#pid_files[@]}"
}

run_command_script() {
  local script_path="$1"
  local exit_code=0
  log "Executing script $script_path (foreground)"
  cmdlog "=== RUN START (foreground) script=$script_path ==="
  cmdlog "project=$PROJECT_NAME"
  cmdlog "project_dir=$PROJECT_DIR"
  if [[ "$INCLUDE_COMMAND_SNAPSHOT_IN_CMD_LOG" == "1" ]]; then
    cmdlog "---- command snapshot ----"
    sed 's/^/| /' "$script_path" >> "$COMMAND_OUTPUT_LOG_FILE"
  fi
  cmdlog "---- output ----"

  if (( COMMAND_TIMEOUT_SECS > 0 )) && command -v timeout >/dev/null 2>&1; then
    timeout -k "$COMMAND_TIMEOUT_KILL_GRACE_SECS" "$COMMAND_TIMEOUT_SECS" bash -lc "cd \"$PROJECT_DIR\" && bash \"$script_path\"" < /dev/null >>"$COMMAND_OUTPUT_LOG_FILE" 2>&1 || exit_code=$?
  else
    bash -lc "cd \"$PROJECT_DIR\" && bash \"$script_path\"" < /dev/null >>"$COMMAND_OUTPUT_LOG_FILE" 2>&1 || exit_code=$?
  fi

  if [[ $exit_code -eq 124 ]]; then
    cmdlog "=== RUN END (foreground) status=TIMEOUT exit_code=$exit_code ==="
    log "TIMEOUT_FG: script=$script_path timeout_secs=$COMMAND_TIMEOUT_SECS"
    if [[ "$TIMEOUT_REQUEUE_TO_BG" == "1" ]]; then
      local run_id=""
      run_id="$(date +%Y%m%dT%H%M%S).$$.$RANDOM.requeue"
      log "REQUEUE_BG: relaunching timed-out foreground run run_id=$run_id"
      run_command_script_bg "$script_path" "$run_id" 0
      return 124
    fi
    return 0
  elif [[ $exit_code -ne 0 ]]; then
    cmdlog "=== RUN END (foreground) status=FAILED exit_code=$exit_code ==="
    log "WARN: $script_path exited with code $exit_code"
  else
    cmdlog "=== RUN END (foreground) status=OK exit_code=$exit_code ==="
    log "DONE: $script_path completed successfully"
  fi
  return 0
}

run_command_script_bg() {
  local script_path="$1"
  local run_id="$2"
  local timeout_secs="${3:-$COMMAND_TIMEOUT_SECS}"
  local pid=""

  log "QUEUE: run_id=$run_id script=$script_path"
  cmdlog "=== RUN START run_id=$run_id ==="
  cmdlog "script=$script_path"
  cmdlog "host=$(hostname)"
  cmdlog "project=$PROJECT_NAME"
  cmdlog "project_dir=$PROJECT_DIR"
  cmdlog "timeout_secs=$timeout_secs"
  if [[ "$INCLUDE_COMMAND_SNAPSHOT_IN_CMD_LOG" == "1" ]]; then
    cmdlog "---- command snapshot ----"
    sed 's/^/| /' "$script_path" >> "$COMMAND_OUTPUT_LOG_FILE"
  fi
  cmdlog "---- output ----"

  (
    local pid_file="$PIDS_DIR/${run_id}.pid"
    cleanup() {
      rm -f "$pid_file" 2>/dev/null || true
      rm -f "$script_path" 2>/dev/null || true
    }
    trap cleanup EXIT

    local exit_code=0
    if (( timeout_secs > 0 )) && command -v timeout >/dev/null 2>&1; then
      timeout -k "$COMMAND_TIMEOUT_KILL_GRACE_SECS" "$timeout_secs" bash -lc "cd \"$PROJECT_DIR\" && bash \"$script_path\"" < /dev/null >>"$COMMAND_OUTPUT_LOG_FILE" 2>&1 || exit_code=$?
    else
      bash -lc "cd \"$PROJECT_DIR\" && bash \"$script_path\"" < /dev/null >>"$COMMAND_OUTPUT_LOG_FILE" 2>&1 || exit_code=$?
    fi

    if [[ $exit_code -eq 124 ]]; then
      cmdlog "=== RUN END run_id=$run_id status=TIMEOUT exit_code=$exit_code ==="
    elif [[ $exit_code -ne 0 ]]; then
      cmdlog "=== RUN END run_id=$run_id status=FAILED exit_code=$exit_code ==="
    else
      cmdlog "=== RUN END run_id=$run_id status=OK exit_code=$exit_code ==="
    fi

    log "DONE_BG: run_id=$run_id exit_code=$exit_code"
  ) &

  pid=$!
  echo "$pid" > "$PIDS_DIR/${run_id}.pid"
  log "START_BG: run_id=$run_id pid=$pid"
}

same_content() {
  local a="$1"
  local b="$2"
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$a" "$b"
  else
    local ha=""
    local hb=""
    ha="$(sha256sum "$a" | awk '{print $1}')" || return 1
    hb="$(sha256sum "$b" | awk '{print $1}')" || return 1
    [[ "$ha" == "$hb" ]]
  fi
}

contains_nul_bytes() {
  local file_path="$1"
  local stripped_copy=""
  stripped_copy="$(mktemp "$STATE_DIR/.nulcheck.XXXXXX")" || return 1
  tr -d '\000' < "$file_path" > "$stripped_copy"
  if cmp -s "$file_path" "$stripped_copy"; then
    rm -f "$stripped_copy" 2>/dev/null || true
    return 1
  fi
  rm -f "$stripped_copy" 2>/dev/null || true
  return 0
}

snapshot_fingerprint() {
  local file_path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file_path" | awk '{print $1}'
  else
    wc -c < "$file_path" | awk '{print $1}'
  fi
}

capture_command_snapshot() {
  local source_path="$1"
  local snapshot_path="$2"
  local tmp_snapshot=""
  local previous_fingerprint=""
  local current_fingerprint=""
  local attempts=0

  tmp_snapshot="$(mktemp "$STATE_DIR/.commands.snapshot.XXXXXX.sh")" || return 1

  while (( attempts < COMMAND_SNAPSHOT_MAX_ATTEMPTS )); do
    attempts=$((attempts + 1))
    cp -f "$source_path" "$tmp_snapshot" 2>/dev/null || true

    if [[ ! -s "$tmp_snapshot" ]]; then
      log "WARN: snapshot attempt $attempts for $source_path produced an empty file"
    elif contains_nul_bytes "$tmp_snapshot"; then
      log "WARN: snapshot attempt $attempts for $source_path contained NUL bytes"
    else
      current_fingerprint="$(snapshot_fingerprint "$tmp_snapshot")"
      if [[ -n "$previous_fingerprint" && "$current_fingerprint" == "$previous_fingerprint" ]]; then
        mv -f "$tmp_snapshot" "$snapshot_path"
        chmod +x "$snapshot_path" 2>/dev/null || true
        return 0
      fi
      previous_fingerprint="$current_fingerprint"
    fi

    : > "$tmp_snapshot"
    sleep "$COMMAND_SNAPSHOT_SETTLE_SECS"
  done

  rm -f "$tmp_snapshot" 2>/dev/null || true
  log "WARN: unable to capture a stable commands.sh snapshot after ${COMMAND_SNAPSHOT_MAX_ATTEMPTS} attempts"
  return 1
}

check_and_mount() {
  local remote="$1"
  local mount_point="$2"
  local folder_id="${3:-}"
  local -a root_folder_arg=()
  local -a cfg_arg=()

  if [[ -n "${RCLONE_CONFIG:-}" ]]; then
    cfg_arg=(--config "$RCLONE_CONFIG")
  fi
  if [[ -n "$folder_id" ]]; then
    root_folder_arg=(--drive-root-folder-id "$folder_id")
  fi

  if ! mkdir -p "$mount_point" 2>/dev/null; then
    log "WARN: resetting unavailable mount path $mount_point"
    reset_mountpoint_path "$mount_point" || return 1
  fi

  if [[ -d "$mount_point" ]] && ! mount_responsive "$mount_point"; then
    log "WARN: clearing stale mount at $mount_point"
    reset_mountpoint_path "$mount_point" || return 1
  fi

  if mountpoint -q "$mount_point"; then
    return 0
  fi

  rclone "${cfg_arg[@]}" mount "$remote" "$mount_point" \
    "${root_folder_arg[@]}" \
    --vfs-cache-mode writes \
    --cache-dir "$RCLONE_CACHE_DIR" \
    --log-level INFO \
    --daemon \
    --poll-interval 20s \
    --buffer-size 32M \
    --vfs-cache-max-size 5G \
    --vfs-cache-max-age 1h \
    --dir-cache-time 15s \
    --drive-skip-gdocs || {
      log "ERROR: failed to mount $remote to $mount_point"
      return 1
    }

  local i=0
  for i in {1..15}; do
    sleep 1
    if mountpoint -q "$mount_point"; then
      log "Mounted $remote on $mount_point"
      return 0
    fi
  done

  log "ERROR: timeout waiting for mount $mount_point"
  return 1
}

ensure_command_channel_ready() {
  if mountpoint -q "$COMMAND_CHANNEL_MOUNT" && mount_responsive "$COMMAND_CHANNEL_MOUNT"; then
    return 0
  fi
  if [[ -z "$RCLONE_REMOTE" ]]; then
    log "ERROR: RCLONE_REMOTE is not set and $COMMAND_CHANNEL_MOUNT is not already mounted"
    return 1
  fi
  check_and_mount "$RCLONE_REMOTE" "$COMMAND_CHANNEL_MOUNT" "$COMMAND_CHANNEL_FOLDER_ID"
}

shutdown_handler() {
  log "Received termination signal, shutting down"
  SHOULD_EXIT=1
}
trap shutdown_handler SIGTERM SIGINT

ensure_runtime_dirs
require_config_value "PROJECT_DIR"
touch "$RELAY_LOG_FILE" "$COMMAND_OUTPUT_LOG_FILE" "$COMMAND_HISTORY_FILE" "$PREVIOUS_COMMAND_SCRIPT"
: > "$RELAY_LOG_FILE"

exec 9>"$RELAY_LOCK_FILE"
if ! flock -n 9; then
  log "relay already running"
  exit 0
fi

if ! [[ "$MAX_CONCURRENT" =~ ^[0-9]+$ ]] || (( MAX_CONCURRENT < 1 )); then
  MAX_CONCURRENT=1
fi
if ! [[ "$COMMAND_TIMEOUT_SECS" =~ ^[0-9]+$ ]] || (( COMMAND_TIMEOUT_SECS < 0 )); then
  COMMAND_TIMEOUT_SECS=0
fi
if ! [[ "$COMMAND_TIMEOUT_KILL_GRACE_SECS" =~ ^[0-9]+$ ]] || (( COMMAND_TIMEOUT_KILL_GRACE_SECS < 0 )); then
  COMMAND_TIMEOUT_KILL_GRACE_SECS=30
fi

if [[ -n "$TTL_HOURS" ]]; then
  if [[ "$TTL_HOURS" =~ ^[0-9]+$ ]]; then
    END_TS=$(( $(date +%s) + TTL_HOURS * 3600 ))
  else
    log "WARN: TTL_HOURS is not an integer ('$TTL_HOURS'); disabling TTL"
    END_TS=0
  fi
fi

if ! ensure_command_channel_ready; then
  exit 1
fi
if [[ ! -e "$COMMAND_SCRIPT_IN" ]]; then
  log_missing_command_script
fi

log "=== relay starting in $WORK_DIR ==="
log "Project name: $PROJECT_NAME"
log "Project directory: $PROJECT_DIR"
log "Command channel mount: $COMMAND_CHANNEL_MOUNT"
log "Command file: $COMMAND_SCRIPT_IN"
log "Mirror root folder id: ${MIRROR_ROOT_FOLDER_ID:-unset}"
ensure_exec

loop_count=0
while [[ "$SHOULD_EXIT" -eq 0 ]]; do
  loop_count=$((loop_count + 1))

  if [[ -s "$COMMAND_SCRIPT_IN" ]]; then
    if [[ -s "$PREVIOUS_COMMAND_SCRIPT" ]] && same_content "$COMMAND_SCRIPT_IN" "$PREVIOUS_COMMAND_SCRIPT"; then
      if (( loop_count % 60 == 0 )); then
        log "$COMMAND_FILE_NAME unchanged; skipping"
      fi
    else
      log "$COMMAND_FILE_NAME changed; queueing execution"
      running="$(count_running_jobs)"
      if [[ "$RUN_IN_BACKGROUND" == "1" ]] && (( running >= MAX_CONCURRENT )); then
        log "BUSY: $running job(s) running; deferring new command"
      else
        run_id="$(date +%Y%m%dT%H%M%S).$$.$RANDOM"
        script_snapshot="$(mktemp "$STATE_DIR/.commands.${run_id}.XXXXXX.sh")"
        if ! capture_command_snapshot "$COMMAND_SCRIPT_IN" "$script_snapshot"; then
          rm -f "$script_snapshot" 2>/dev/null || true
          log "WARN: skipping execution because commands.sh never settled into a valid snapshot"
          continue
        fi

        append_to_history "$script_snapshot"
        cp -f "$script_snapshot" "$PREVIOUS_COMMAND_SCRIPT"

        if [[ "$RUN_IN_BACKGROUND" == "1" ]]; then
          run_command_script_bg "$script_snapshot" "$run_id"
        else
          run_command_script "$script_snapshot"
          rc=$?
          if [[ $rc -ne 124 ]]; then
            rm -f "$script_snapshot" 2>/dev/null || true
          fi
        fi
      fi
    fi
  else
    if [[ ! -e "$COMMAND_SCRIPT_IN" ]]; then
      if (( loop_count == 1 || loop_count % 60 == 0 )); then
        log_missing_command_script
      fi
    fi
  fi

  if [[ ! -s "$COMMAND_SCRIPT_IN" && -s "$PREVIOUS_COMMAND_SCRIPT" ]]; then
    log "No script to run (missing or empty: $COMMAND_SCRIPT_IN)"
  fi

  if [[ "$END_TS" -gt 0 && "$(date +%s)" -ge "$END_TS" ]]; then
    log "TTL reached ($TTL_HOURS h). Exiting."
    SHOULD_EXIT=1
  fi

  publish_logs
  if [[ "$SHOULD_EXIT" -eq 0 ]]; then
    sleep "$SLEEP_SECS"
  fi
done

log "=== relay exiting ==="
