#!/usr/bin/env bash
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
ensure_runtime_dirs

EMAIL_START_OK=0
NOTIFIER_MODE="standalone"
SLURM_ENV_DETECTED=0

if [[ -n "${SLURM_JOB_ID:-}" ]]; then
  NOTIFIER_MODE="slurm"
  SLURM_ENV_DETECTED=1
fi

JOB_ID="${SLURM_JOB_ID:-no-slurm}"
JOB_NAME="${SLURM_JOB_NAME:-unknown}"
if [[ -z "$JOB_NAME" || "$JOB_NAME" == "unknown" || "$JOB_NAME" == "Unknown" || "$JOB_NAME" == "UNKNOWN" ]]; then
  JOB_NAME="$PROJECT_NAME"
fi
HOST="$(hostname)"
WORKDIR="$(pwd)"

email_log_event() {
  local status="$1"
  local detail="${2:-}"
  local ts=""
  ts="$(TZ="$REPORT_TZ_ET" date -Is 2>/dev/null || echo unknown)"
  mkdir -p "$(dirname "$EMAIL_LOG_FILE")" 2>/dev/null || true
  {
    printf '[%s] job_notifier.sh status=%s\n' "$ts" "$status"
    printf 'mode=%s\n' "$NOTIFIER_MODE"
    printf 'job_id=%s\n' "${JOB_ID:-unknown}"
    printf 'job_name=%s\n' "${JOB_NAME:-unknown}"
    [[ -n "$detail" ]] && printf '%s\n' "$detail"
    printf '\n'
  } >> "$EMAIL_LOG_FILE" 2>/dev/null || true
}

email_on_err() {
  local exit_code=$?
  if (( EMAIL_START_OK == 0 )); then
    email_log_event "FAIL_START" "exit_code=$exit_code"
  fi
  return "$exit_code"
}
trap email_on_err ERR

if [[ -z "${SMTP_USER:-}" ]]; then
  email_log_event "FAIL_START" "missing=SMTP_USER"
  echo "Set SMTP_USER in .env or your shell" >&2
  exit 1
fi
if [[ -z "${SMTP_PASS:-}" ]]; then
  email_log_event "FAIL_START" "missing=SMTP_PASS"
  echo "Set SMTP_PASS or provide NOTIFIER_PASSWORD_FILE" >&2
  exit 1
fi

mapfile -t recipients < <(join_notification_recipients)
if (( ${#recipients[@]} == 0 )); then
  email_log_event "FAIL_START" "missing=notification_recipients"
  echo "Set NOTIFICATION_TO_PRIMARY and optionally NOTIFICATION_TO_SECONDARY" >&2
  exit 1
fi

EMAIL_START_OK=1
email_log_event "START_OK" "slurm_env_detected=$SLURM_ENV_DETECTED"

LOCKFILE="${EMAIL_LOCKFILE:-$STATE_DIR/.job_notifier.lock.${JOB_ID}}"
mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null || true
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  exit 0
fi

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

is_unknown() {
  local value="${1:-}"
  [[ -z "$value" || "$value" == "unknown" || "$value" == "UNKNOWN" || "$value" == "N/A" || "$value" == "Unknown" || "$value" == "NOT_SET" ]]
}

epoch_to_tz() {
  local epoch="$1"
  local tz="$2"
  TZ="$tz" date -d "@$epoch" "+%Y-%m-%d %H:%M:%S %Z (%z)" 2>/dev/null || echo unknown
}

slurm_ts_to_tz() {
  local ts="$1"
  local tz="$2"
  if is_unknown "$ts"; then
    echo unknown
    return
  fi
  local epoch=""
  epoch="$(TZ="$SLURM_TIME_TZ" date -d "$ts" +%s 2>/dev/null || true)"
  if [[ -z "$epoch" ]]; then
    echo unknown
    return
  fi
  epoch_to_tz "$epoch" "$tz"
}

get_slurm_times() {
  SLURM_START="unknown"
  SLURM_TIMELIMIT="unknown"
  SLURM_TIMELEFT="unknown"
  SLURM_END_EST="unknown"

  local info=""
  if info=$(squeue -j "$JOB_ID" -h -o "%S|%e|%l|%L" 2>/dev/null) && [[ -n "$info" ]]; then
    IFS='|' read -r squeue_start squeue_end squeue_limit squeue_left <<< "$info"
    ! is_unknown "${squeue_start:-}" && SLURM_START="$squeue_start"
    ! is_unknown "${squeue_limit:-}" && SLURM_TIMELIMIT="$squeue_limit"
    ! is_unknown "${squeue_left:-}" && SLURM_TIMELEFT="$squeue_left"
    ! is_unknown "${squeue_end:-}" && SLURM_END_EST="$squeue_end"
  fi

  if is_unknown "$SLURM_START" || is_unknown "$SLURM_TIMELIMIT" || is_unknown "$SLURM_END_EST"; then
    info=""
    if info=$(sacct -j "$JOB_ID" -X -n -P -o Start,End,Timelimit 2>/dev/null | head -n1) && [[ -n "$info" ]]; then
      IFS='|' read -r acct_start acct_end acct_limit <<< "$info"
      is_unknown "$SLURM_START" && ! is_unknown "${acct_start:-}" && SLURM_START="$acct_start"
      is_unknown "$SLURM_TIMELIMIT" && ! is_unknown "${acct_limit:-}" && SLURM_TIMELIMIT="$acct_limit"
      is_unknown "$SLURM_END_EST" && ! is_unknown "${acct_end:-}" && SLURM_END_EST="$acct_end"
    fi
  fi

  if is_unknown "$SLURM_END_EST"; then
    local left_secs
    left_secs="$(time_to_seconds "$SLURM_TIMELEFT")"
    if (( left_secs > 0 )); then
      SLURM_END_EST="$(date -d "@$(( $(date +%s) + left_secs ))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo unknown)"
      return
    fi

    local tl_seconds=""
    tl_seconds="$(time_to_seconds "$SLURM_TIMELIMIT")"
    if (( tl_seconds > 0 )) && ! is_unknown "$SLURM_START"; then
      local start_epoch=""
      start_epoch="$(date -d "$SLURM_START" +%s 2>/dev/null || echo "")"
      if [[ -n "$start_epoch" ]]; then
        SLURM_END_EST="$(date -d "@$(( start_epoch + tl_seconds ))" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo unknown)"
      fi
    fi
  fi
}

get_final_state() {
  local tries=0
  local state=""
  while (( tries < 60 )); do
    state="$(sacct -j "$JOB_ID" -X -o State -n 2>/dev/null | head -n1 | awk '{print $1}')"
    if [[ -n "$state" ]]; then
      echo "$state"
      return
    fi
    sleep 10
    tries=$((tries + 1))
  done
  echo "UNKNOWN"
}

cleanup_email_sentinels_after_final() {
  local delay="${EMAIL_SENTINEL_CLEANUP_DELAY_SECONDS:-30}"
  if [[ ! "$delay" =~ ^[0-9]+$ ]]; then
    delay=30
  fi

  if [[ ! -d "$STATE_DIR" ]]; then
    email_log_event "SENTINEL_CLEANUP_SKIP" "missing_state_dir=$STATE_DIR"
    return 0
  fi

  local -a sentinels=()
  mapfile -t sentinels < <(find "$STATE_DIR" -maxdepth 1 -type f -name '.email_notifier.started.*' 2>/dev/null || true)

  if (( delay > 0 )); then
    sleep "$delay"
  fi

  local sentinel=""
  local removed=0
  for sentinel in "${sentinels[@]}"; do
    case "$sentinel" in
      "$STATE_DIR"/.email_notifier.started.*)
        if [[ -f "$sentinel" ]]; then
          rm -f -- "$sentinel" 2>/dev/null || true
          removed=$((removed + 1))
        fi
        ;;
    esac
  done

  email_log_event "SENTINEL_CLEANUP" "delay_seconds=$delay removed=$removed state_dir=$STATE_DIR"
}

expand_deferred_string() {
  local raw="${1:-}"
  eval "printf '%s' \"$raw\""
}

resolve_mail_log_file() {
  local file="$1"
  case "$file" in
    relay.log) echo "$RELAY_LOG_FILE" ;;
    remote.log) echo "$RELAY_LOG_FILE" ;;
    supervisor.log) echo "$SUPERVISOR_LOG_FILE" ;;
    command-output.log) echo "$COMMAND_OUTPUT_LOG_FILE" ;;
    sync.log) echo "$SYNC_LOG_FILE" ;;
    email.log) echo "$EMAIL_LOG_FILE" ;;
    *)
      if [[ "$file" == /* ]]; then
        echo "$file"
      elif [[ -f "$file" ]]; then
        echo "$file"
      elif [[ -f "$LOG_DIR/$file" ]]; then
        echo "$LOG_DIR/$file"
      else
        echo "$file"
      fi
      ;;
  esac
}

should_skip_log_entry() {
  local raw="$1"
  local resolved="$2"

  if (( SLURM_ENV_DETECTED == 0 )) && [[ "$raw" == *"SLURM_JOB_ID"* || "$resolved" == slurm-*".out" ]]; then
    return 0
  fi

  [[ -f "$resolved" ]] || return 0
  return 1
}

build_log_sections() {
  local expanded_mail_logs=""
  expanded_mail_logs="$(expand_deferred_string "$MAIL_LOG_FILES")"

  local split_ifs="$IFS"
  local -a files=()
  local -a included=()
  IFS=' '
  read -r -a files <<< "$expanded_mail_logs"
  IFS="$split_ifs"

  local file=""
  local resolved_file=""
  local section=""
  for file in "${files[@]}"; do
    [[ -n "$file" ]] || continue
    resolved_file="$(resolve_mail_log_file "$file")"
    if should_skip_log_entry "$file" "$resolved_file"; then
      continue
    fi

    included+=("$resolved_file")
    section+=$'\n------------------------------\n'
    section+="Tail of log file: $resolved_file"$'\n'
    section+="$(tail -n 40 "$resolved_file")"$'\n'
  done

  if (( ${#included[@]} == 0 )); then
    section+=$'\nNo current log files were attached.\n'
  fi

  printf '%s' "$section"
}

build_project_summary() {
  cat <<EOF
Project name:            $PROJECT_NAME
Notifier mode:           $NOTIFIER_MODE
Execution side:          remote runtime system where job_notifier.sh is running
Host:                    $HOST
Workdir:                 $WORKDIR
Project directory:       $PROJECT_DIR
Project instance root:   $PROJECT_INSTANCE_ROOT
Command channel mount:   $COMMAND_CHANNEL_MOUNT
Command file name:       $COMMAND_FILE_NAME
Mirror remote:           $RCLONE_REMOTE
Mirror subdir:           $MIRROR_REMOTE_SUBDIR
Relay poll interval:     $SLEEP_SECS
Supervisor interval:     $INTERVAL_SEC
Run in background:       $RUN_IN_BACKGROUND
Publish logs:            $PUBLISH_LOGS
Log directory:           $LOG_DIR
State directory:         $STATE_DIR
EOF
}

send_mail() {
  local status="$1"
  local icon="ℹ️"
  case "$status" in
    STARTED*) icon="✅" ;;
    *COMPLETED*|*FINISHED*) icon="✅" ;;
    *FAILED*|*TIMEOUT*|*CANCELLED*) icon="❌" ;;
  esac

  local now_epoch=""
  now_epoch="$(date +%s)"
  local now_et now_gmt
  now_et="$(epoch_to_tz "$now_epoch" "$REPORT_TZ_ET")"
  now_gmt="$(epoch_to_tz "$now_epoch" "$REPORT_TZ_GMT")"

  local subject=""
  local body=""

  if (( SLURM_ENV_DETECTED == 1 )); then
    get_slurm_times
    local start_et start_gmt end_et end_gmt
    start_et="$(slurm_ts_to_tz "$SLURM_START" "$REPORT_TZ_ET")"
    start_gmt="$(slurm_ts_to_tz "$SLURM_START" "$REPORT_TZ_GMT")"
    end_et="$(slurm_ts_to_tz "$SLURM_END_EST" "$REPORT_TZ_ET")"
    end_gmt="$(slurm_ts_to_tz "$SLURM_END_EST" "$REPORT_TZ_GMT")"
    subject="[Remote Pilot $JOB_ID] $status $icon"
    body=$(cat <<EOF
Status:          $status
Job ID:          $JOB_ID
Job name:        $JOB_NAME
Project:         $PROJECT_NAME
Host:            $HOST
Workdir:         $WORKDIR

Current time (ET):       $now_et
Current time (GMT):      $now_gmt
Slurm TZ assumed:        $SLURM_TIME_TZ

Nominal start (ET):      $start_et
Nominal start (GMT):     $start_gmt
Time limit (walltime):   $SLURM_TIMELIMIT
Expected end (ET):       $end_et
Expected end (GMT):      $end_gmt
Time left (per Slurm):   $SLURM_TIMELEFT

This job is running on a remote resource.
EOF
)

    case "$status" in
      STARTED*)
        body+=$'\nYou will receive another email when this job finishes.\n'
        ;;
      *)
        body+=$'\nThe job has finished; this message reflects the final Slurm state.\n'
        ;;
    esac
  else
    subject="[Remote Pilot $PROJECT_NAME] $status (non-Slurm) $icon"
    body=$(cat <<EOF
Status:                  $status
Project:                 $PROJECT_NAME
Job name:                $JOB_NAME
Host:                    $HOST
Workdir:                 $WORKDIR
Current time (ET):       $now_et
Current time (GMT):      $now_gmt

Could not detect a Slurm environment or usable Slurm job parameters.
Using standalone project notification mode instead of Slurm job reporting.

$(build_project_summary)
EOF
)
    body+=$'\nThis message reflects the current project startup state and the available logs so far.\n'
  fi

  body+="$(build_log_sections)"

  local -a mail_cmd=("$SCRIPT_DIR/send_email.py")
  local recipient=""
  for recipient in "${recipients[@]}"; do
    mail_cmd+=(--to "$recipient")
  done
  mail_cmd+=(--subject "$subject" --body "$body")
  "${mail_cmd[@]}"
}

main() {
  if (( SLURM_ENV_DETECTED == 0 )); then
    send_mail "STARTED"
    return 0
  fi

  send_mail "STARTED"
  get_slurm_times

  local left_secs=0
  left_secs="$(time_to_seconds "$SLURM_TIMELEFT")"
  local sleep_secs=$(( left_secs - FINISH_MARGIN_SECONDS ))
  (( sleep_secs < 0 )) && sleep_secs=0
  if (( sleep_secs > 0 )); then
    sleep "$sleep_secs"
  fi

  local final_state=""
  final_state="$(get_final_state)"
  send_mail "FINISHED (state=$final_state)"
  cleanup_email_sentinels_after_final
}

main "$@"
