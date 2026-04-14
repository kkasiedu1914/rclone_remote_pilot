#!/usr/bin/env bash
set -eEuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/config.sh"
load_project_env "$SCRIPT_DIR"
ensure_runtime_dirs

EMAIL_START_OK=0

email_log_event() {
  local status="$1"
  local detail="${2:-}"
  local ts=""
  ts="$(TZ="$REPORT_TZ_ET" date -Is 2>/dev/null || echo unknown)"
  {
    printf '[%s] job_notifier.sh status=%s\n' "$ts" "$status"
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
join_by() {
  local sep="$1"
  shift
  local out=""
  local item=""
  for item in "$@"; do
    if [[ -n "$out" ]]; then
      out+="$sep"
    fi
    out+="$item"
  done
  printf '%s' "$out"
}

JOB_ID="${SLURM_JOB_ID:-unknown}"
JOB_NAME="${SLURM_JOB_NAME:-unknown}"
if [[ -z "$JOB_NAME" || "$JOB_NAME" == "unknown" || "$JOB_NAME" == "Unknown" || "$JOB_NAME" == "UNKNOWN" ]]; then
  JOB_NAME="$PROJECT_NAME"
fi
HOST="$(hostname)"
WORKDIR="$(pwd)"

mapfile -t recipients < <(join_notification_recipients)

STARTUP_NOTE=""
if [[ -z "${SLURM_JOB_ID:-}" ]]; then
  STARTUP_NOTE="missing_optional=SLURM_JOB_ID"
fi

declare -a startup_missing=()
if [[ -z "${SMTP_USER:-}" ]]; then
  startup_missing+=("SMTP_USER")
fi
if [[ -z "${SMTP_PASS:-}" ]]; then
  startup_missing+=("SMTP_PASS_or_NOTIFIER_PASSWORD_FILE")
fi
if (( ${#recipients[@]} == 0 )); then
  startup_missing+=("notification_recipients")
fi
if (( ${#startup_missing[@]} > 0 )); then
  startup_detail="missing_required=$(join_by "," "${startup_missing[@]}")"
  if [[ -n "$STARTUP_NOTE" ]]; then
    startup_detail="$STARTUP_NOTE; $startup_detail"
  fi
  email_log_event "FAIL_START" "$startup_detail"
  echo "job_notifier.sh cannot start: $startup_detail" >&2
  exit 1
fi

EMAIL_START_OK=1
email_log_event "START_OK" "$STARTUP_NOTE"

LOCKFILE="${EMAIL_LOCKFILE:-$STATE_DIR/.job_notifier.lock.${JOB_ID}}"
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

  if is_unknown "$JOB_ID"; then
    return
  fi

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
  if is_unknown "$JOB_ID"; then
    echo "UNAVAILABLE"
    return
  fi

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

send_mail() {
  local status="$1"
  local icon="ℹ️"
  case "$status" in
    STARTED*) icon="✅" ;;
    *COMPLETED*|*FINISHED*) icon="✅" ;;
    *FAILED*|*TIMEOUT*|*CANCELLED*) icon="❌" ;;
  esac

  get_slurm_times
  local now_epoch=""
  now_epoch="$(date +%s)"
  local now_et now_gmt start_et start_gmt end_et end_gmt
  now_et="$(epoch_to_tz "$now_epoch" "$REPORT_TZ_ET")"
  now_gmt="$(epoch_to_tz "$now_epoch" "$REPORT_TZ_GMT")"
  start_et="$(slurm_ts_to_tz "$SLURM_START" "$REPORT_TZ_ET")"
  start_gmt="$(slurm_ts_to_tz "$SLURM_START" "$REPORT_TZ_GMT")"
  end_et="$(slurm_ts_to_tz "$SLURM_END_EST" "$REPORT_TZ_ET")"
  end_gmt="$(slurm_ts_to_tz "$SLURM_END_EST" "$REPORT_TZ_GMT")"

  local subject="[Remote Pilot] $status $icon"
  if ! is_unknown "$JOB_ID"; then
    subject="[Remote Pilot $JOB_ID] $status $icon"
  fi

  local body=""
  body+="Status:          $status"$'\n'
  if ! is_unknown "$JOB_ID"; then
    body+="Job ID:          $JOB_ID"$'\n'
  fi
  if ! is_unknown "$JOB_NAME"; then
    body+="Job name:        $JOB_NAME"$'\n'
  fi
  body+="Host:            $HOST"$'\n'
  body+="Workdir:         $WORKDIR"$'\n'
  body+=$'\n'
  body+="Current time (ET):       $now_et"$'\n'
  body+="Current time (GMT):      $now_gmt"$'\n'
  body+="Slurm TZ assumed:        $SLURM_TIME_TZ"$'\n'
  if is_unknown "$JOB_ID"; then
    body+=$'\n'
    body+="Slurm metadata note: SLURM_JOB_ID was not present in the environment."$'\n'
    body+="Slurm-specific timing and final-state details are unavailable for this run."$'\n'
  else
    body+=$'\n'
    if ! is_unknown "$SLURM_START"; then
      body+="Nominal start (ET):      $start_et"$'\n'
      body+="Nominal start (GMT):     $start_gmt"$'\n'
    fi
    if ! is_unknown "$SLURM_TIMELIMIT"; then
      body+="Time limit (walltime):   $SLURM_TIMELIMIT"$'\n'
    fi
    if ! is_unknown "$SLURM_END_EST"; then
      body+="Expected end (ET):       $end_et"$'\n'
      body+="Expected end (GMT):      $end_gmt"$'\n'
    fi
    if ! is_unknown "$SLURM_TIMELEFT"; then
      body+="Time left (per Slurm):   $SLURM_TIMELEFT"$'\n'
    fi
  fi
  body+=$'\n'
  body+="This job is running on a remote resource."$'\n'

  case "$status" in
    STARTED*)
      body+=$'\nYou will receive another email when this job finishes.\n'
      ;;
    *)
      body+=$'\nThe job has finished; this message reflects the final Slurm state.\n'
      ;;
  esac

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

  local split_ifs="$IFS"
  local -a files=()
  IFS=' '
  read -r -a files <<< "$MAIL_LOG_FILES"
  IFS="$split_ifs"
  local file=""
  local resolved_file=""
  for file in "${files[@]}"; do
    resolved_file="$(resolve_mail_log_file "$file")"
    if [[ -f "$resolved_file" ]]; then
      body+=$'\n------------------------------\n'
      body+="Tail of log file: $resolved_file"$'\n'
      body+="$(tail -n 40 "$resolved_file")"$'\n'
    fi
  done

  local -a mail_cmd=("$SCRIPT_DIR/send_email.py")
  local recipient=""
  for recipient in "${recipients[@]}"; do
    mail_cmd+=(--to "$recipient")
  done
  mail_cmd+=(--subject "$subject" --body "$body")
  "${mail_cmd[@]}"
}

main() {
  send_mail "STARTED"
  if is_unknown "$JOB_ID"; then
    email_log_event "FOLLOWUP_SKIPPED" "missing_optional=SLURM_JOB_ID"
    return 0
  fi
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
}

main "$@"
