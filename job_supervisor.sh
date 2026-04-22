#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
ensure_runtime_dirs

PROJ="$SCRIPT_DIR"
LOG="$SUPERVISOR_LOG_FILE"
INTERVAL_SEC="${INTERVAL_SEC:-1800}"
RELAY_CONTROL_SCRIPT="$PROJ/relayctl.sh"
NOTIFIER_SCRIPT="$PROJ/job_notifier.sh"
MOUNT_REPAIR_SCRIPT="$PROJ/repair_mount.sh"
RUN_OUT="$STATE_DIR/.relayctl.last.out"

exec 8>"$SUPERVISOR_LOCK_FILE"
if ! flock -n 8; then
  printf '[%s] %s\n' "$(date -Is)" "supervisor already running; lock=$SUPERVISOR_LOCK_FILE"
  exit 0
fi

if [[ -z "${SLURM_JOB_NAME:-}" || "${SLURM_JOB_NAME:-}" == "unknown" || "${SLURM_JOB_NAME:-}" == "Unknown" || "${SLURM_JOB_NAME:-}" == "UNKNOWN" ]]; then
  export SLURM_JOB_NAME="$JOB_NOTIFICATION_NAME"
fi

: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

ts() { date -Is; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }

time_to_seconds() {
  local t="$1"
  local days=0 h=0 m=0 s=0

  if [[ -z "$t" || "$t" == "UNLIMITED" || "$t" == "NOT_SET" || "$t" == "N/A" || "$t" == "Unknown" || "$t" == "UNKNOWN" ]]; then
    echo 0
    return
  fi

  if [[ "$t" == *-* ]]; then
    days="${t%%-*}"
    t="${t#*-}"
  fi

  local -a parts=()
  IFS=':' read -r -a parts <<<"$t"
  if (( ${#parts[@]} == 3 )); then
    h="${parts[0]}"; m="${parts[1]}"; s="${parts[2]}"
  elif (( ${#parts[@]} == 2 )); then
    m="${parts[0]}"; s="${parts[1]}"
  elif (( ${#parts[@]} == 1 )); then
    s="${parts[0]}"
  else
    echo 0
    return
  fi

  echo $((10#$days * 86400 + 10#${h:-0} * 3600 + 10#${m:-0} * 60 + 10#${s:-0}))
}

get_time_left_seconds() {
  [[ -n "${SLURM_JOB_ID:-}" ]] || return 1
  command -v squeue >/dev/null 2>&1 || return 1

  local left=""
  left="$(squeue -j "$SLURM_JOB_ID" -h -o "%L" 2>/dev/null | head -n 1 || true)"
  [[ -n "$left" ]] || return 1
  time_to_seconds "$left"
}

stop_relay_now() {
  if [[ -x "$RELAY_CONTROL_SCRIPT" ]]; then
    bash "$RELAY_CONTROL_SCRIPT" stop >/dev/null 2>&1 || true
  fi
  pkill -f '[r]elay.sh' 2>/dev/null || true
  rm -f "$RELAY_PID_FILE" "$RELAY_LOCK_FILE" 2>/dev/null || true
}

run_mount_repair() {
  if [[ -x "$MOUNT_REPAIR_SCRIPT" ]]; then
    bash "$MOUNT_REPAIR_SCRIPT" >/dev/null 2>&1 || log "WARN repair_mount.sh exited non-zero"
  else
    log "WARN repair_mount.sh not found; skipping mount repair"
  fi
}

stop_requested=0
sleep_pid=""
near_walltime_handled=0
cleanup_ran=0
email_missing_warned=0
iter=0

cleanup_email_sentinels() {
  if [[ -n "${EMAIL_SENTINEL_FILE:-}" && -e "$EMAIL_SENTINEL_FILE" ]]; then
    find "$STATE_DIR" -maxdepth 1 -type f -name '.email_notifier.started.*' ! -samefile "$EMAIL_SENTINEL_FILE" -delete 2>/dev/null || true
  else
    find "$STATE_DIR" -maxdepth 1 -type f -name '.email_notifier.started.*' -delete 2>/dev/null || true
  fi
}

cleanup_on_exit() {
  if (( cleanup_ran == 1 )); then
    return
  fi
  cleanup_ran=1
  log "INFO Cleanup: stopping relay and repairing mount"
  stop_relay_now
  run_mount_repair
}

trap '
  stop_requested=1
  [[ -n "${sleep_pid:-}" ]] && kill "$sleep_pid" 2>/dev/null || true
  log "SIGNAL Stop requested"
  cleanup_on_exit
' INT TERM

log "START Job supervisor"
log "INFO Working directory: $PROJ"

while (( stop_requested == 0 )); do
  iter=$((iter + 1))

  if [[ ! -x "$RELAY_CONTROL_SCRIPT" ]]; then
    log "ERROR relayctl.sh not found; exiting"
    exit 1
  fi

  : > "$RUN_OUT"
  if bash "$RELAY_CONTROL_SCRIPT" restart >"$RUN_OUT" 2>&1; then
    status="OK"
    if [[ "$EMAIL_ON_START" == "1" && ! -f "$EMAIL_SENTINEL_FILE" ]]; then
      if [[ -x "$NOTIFIER_SCRIPT" ]]; then
        (bash "$NOTIFIER_SCRIPT" >/dev/null 2>&1 || log "WARN job_notifier.sh exited non-zero") &
        touch "$EMAIL_SENTINEL_FILE" 2>/dev/null || true
        log "INFO job_notifier.sh launched once; sentinel=$EMAIL_SENTINEL_FILE"
      elif (( email_missing_warned == 0 )); then
        log "WARN job_notifier.sh not found; skipping notifications"
        email_missing_warned=1
      fi
    fi
  else
    status="FAIL"
    log "ERROR restart failed (relayctl output follows)"
    log "ERROR relayctl command: bash $RELAY_CONTROL_SCRIPT restart"
    log "ERROR mount target: $COMMAND_CHANNEL_MOUNT"
    log "ERROR relay log path: $RELAY_LOG_FILE"
    log "ERROR supervisor log path: $SUPERVISOR_LOG_FILE"
    log "ERROR --- relayctl output begin ---"
    tail -n 50 "$RUN_OUT"
    log "ERROR --- relayctl output end ---"
    rm -f "$RELAY_PID_FILE" "$RELAY_LOCK_FILE"
    find "$STATE_DIR" -type f -name '.commands.*.sh' -delete 2>/dev/null || true
    pkill -f '[r]elay.sh' 2>/dev/null || true
    log "INFO running mount repair after failed restart"
    run_mount_repair
  fi

  left_secs=""
  if (( near_walltime_handled == 0 )); then
    left_secs="$(get_time_left_seconds 2>/dev/null || true)"
    if [[ -n "$left_secs" ]] && (( left_secs > 0 )) && (( left_secs <= FINISH_MARGIN_SECONDS )); then
      log "INFO Near walltime (time_left=${left_secs}s <= margin=${FINISH_MARGIN_SECONDS}s)"
      cleanup_email_sentinels
      cleanup_on_exit
      near_walltime_handled=1
      stop_requested=1
      break
    fi
  fi

  sleep_for="$INTERVAL_SEC"
  if [[ -n "$left_secs" ]] && (( left_secs > FINISH_MARGIN_SECONDS )); then
    next_wake=$(( left_secs - FINISH_MARGIN_SECONDS ))
    if (( next_wake < sleep_for )); then
      sleep_for="$next_wake"
    fi
    if (( sleep_for < 1 )); then
      sleep_for=1
    fi
  fi

  log "HB iter=$iter restart=$status next_check_in=${sleep_for}s"
  sleep "$sleep_for" &
  sleep_pid=$!
  wait "$sleep_pid" || true
  sleep_pid=""
done

cleanup_on_exit
log "END Loop finished"
