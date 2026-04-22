#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

first_defined_value() {
  local default_value="$1"
  shift

  local candidate=""
  for candidate in "$@"; do
    if [[ -n "$candidate" && ${!candidate+x} ]]; then
      printf '%s' "${!candidate}"
      return 0
    fi
  done

  printf '%s' "$default_value"
}

normalize_project_prefix() {
  local raw_name="$1"
  printf '%s' "$raw_name" \
    | tr '[:lower:]-./' '[:upper:]___' \
    | sed 's/[^A-Z0-9_]/_/g'
}

load_project_env() {
  local project_root="${1:-}"
  if [[ -z "$project_root" ]]; then
    project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  fi

  local caller_selected_project="${REMOTE_PILOT_PROJECT:-}"
  local caller_selected_project_env_dir="${REMOTE_PILOT_PROJECT_ENV_DIR:-}"
  local caller_selected_project_file="${REMOTE_PILOT_PROJECT_FILE:-}"
  local caller_selected_project_local_file="${REMOTE_PILOT_PROJECT_LOCAL_FILE:-}"

  local base_env_file="${REMOTE_PILOT_ENV_FILE:-$project_root/.env}"
  if [[ -f "$base_env_file" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$base_env_file"
    set +a
  fi

  export REMOTE_PILOT_HOME="${REMOTE_PILOT_HOME:-$project_root}"
  export PROJECT_ROOT="${PROJECT_ROOT:-$project_root}"
  export PROJECT_ENV_FILE="$base_env_file"

  export REMOTE_PILOT_PROJECT="${caller_selected_project:-${REMOTE_PILOT_PROJECT:-${PROJECT_NAME:-default}}}"
  export REMOTE_PILOT_PROJECT_PREFIX="$(normalize_project_prefix "$REMOTE_PILOT_PROJECT")"
  local default_project_env_dir="$REMOTE_PILOT_HOME/projects"
  export REMOTE_PILOT_PROJECT_ENV_DIR="${caller_selected_project_env_dir:-${REMOTE_PILOT_PROJECT_ENV_DIR:-$default_project_env_dir}}"
  export REMOTE_PILOT_PROJECT_FILE="${caller_selected_project_file:-${REMOTE_PILOT_PROJECT_FILE:-$REMOTE_PILOT_PROJECT_ENV_DIR/${REMOTE_PILOT_PROJECT}.env}}"
  export REMOTE_PILOT_PROJECT_LOCAL_FILE="${caller_selected_project_local_file:-${REMOTE_PILOT_PROJECT_LOCAL_FILE:-$REMOTE_PILOT_PROJECT_ENV_DIR/${REMOTE_PILOT_PROJECT}.local.env}}"

  # Recover from stale global config that points the project env dir outside the pilot repo.
  if [[ ! -f "$REMOTE_PILOT_PROJECT_FILE" && "$REMOTE_PILOT_PROJECT_ENV_DIR" != "$default_project_env_dir" ]]; then
    local fallback_project_file="$default_project_env_dir/${REMOTE_PILOT_PROJECT}.env"
    local fallback_project_local_file="$default_project_env_dir/${REMOTE_PILOT_PROJECT}.local.env"
    if [[ -f "$fallback_project_file" || -f "$fallback_project_local_file" ]]; then
      export REMOTE_PILOT_PROJECT_ENV_DIR="$default_project_env_dir"
      export REMOTE_PILOT_PROJECT_FILE="$fallback_project_file"
      export REMOTE_PILOT_PROJECT_LOCAL_FILE="$fallback_project_local_file"
    fi
  fi

  if [[ -f "$REMOTE_PILOT_PROJECT_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$REMOTE_PILOT_PROJECT_FILE"
    set +a
  fi
  if [[ -f "$REMOTE_PILOT_PROJECT_LOCAL_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$REMOTE_PILOT_PROJECT_LOCAL_FILE"
    set +a
  fi

  local host_tag=""
  host_tag="$(hostname -s 2>/dev/null || echo remote-host)"
  local pref="$REMOTE_PILOT_PROJECT_PREFIX"

  export PROJECT_NAME="$REMOTE_PILOT_PROJECT"
  export REMOTE_ACCESS_EMAIL="$(first_defined_value "compucatalysis@gmail.com" "${pref}_REMOTE_ACCESS_EMAIL" REMOTE_ACCESS_EMAIL)"

  export PROJECT_DIR="$(first_defined_value "$REMOTE_PILOT_HOME" "${pref}_PROJECT_DIR" PROJECT_DIR WORK_DIR)"
  export PROJECT_INSTANCE_ROOT="$(first_defined_value "$PROJECT_DIR/.remote-pilot/$REMOTE_PILOT_PROJECT" "${pref}_PROJECT_INSTANCE_ROOT" PROJECT_INSTANCE_ROOT)"
  export WORK_DIR="$PROJECT_DIR"
  export SYNC_SOURCE_DIR="$(first_defined_value "$PROJECT_DIR" "${pref}_SYNC_SOURCE_DIR" SYNC_SOURCE_DIR)"

  export LOG_DIR="$(first_defined_value "$PROJECT_INSTANCE_ROOT/logs" "${pref}_LOG_DIR" LOG_DIR)"
  export STATE_DIR="$(first_defined_value "$PROJECT_INSTANCE_ROOT/state" "${pref}_STATE_DIR" STATE_DIR)"

  export COMMAND_CHANNEL_MOUNT="$(first_defined_value "$HOME/remote-pilot/${REMOTE_PILOT_PROJECT}/command-channel" "${pref}_COMMAND_CHANNEL_MOUNT" COMMAND_CHANNEL_MOUNT MOUNT_IN_DIR)"
  export COMMAND_CHANNEL_FOLDER_ID="$(first_defined_value "" "${pref}_COMMAND_CHANNEL_FOLDER_ID" COMMAND_CHANNEL_FOLDER_ID MOUNT_FOLD_ID)"
  export COMMAND_FILE_NAME="$(first_defined_value "commands.sh" "${pref}_COMMAND_FILE_NAME" COMMAND_FILE_NAME)"
  export COMMAND_CHANNEL_LOG_SUBDIR="$(first_defined_value "logs" "${pref}_COMMAND_CHANNEL_LOG_SUBDIR" COMMAND_CHANNEL_LOG_SUBDIR)"
  export COMMAND_CHANNEL_LOG_DIR="$(first_defined_value "$COMMAND_CHANNEL_MOUNT/$COMMAND_CHANNEL_LOG_SUBDIR" "${pref}_COMMAND_CHANNEL_LOG_DIR" COMMAND_CHANNEL_LOG_DIR PUBLISH_LOGS_DIR)"

  export MIRROR_ROOT_FOLDER_ID="$(first_defined_value "" "${pref}_MIRROR_ROOT_FOLDER_ID" MIRROR_ROOT_FOLDER_ID SYNC_OUT_DIR)"
  export RCLONE_REMOTE="$(first_defined_value "" "${pref}_RCLONE_REMOTE" RCLONE_REMOTE OUT_REMOTE)"
  export MIRROR_REMOTE_SUBDIR="$(first_defined_value "$REMOTE_PILOT_PROJECT/$host_tag" "${pref}_MIRROR_REMOTE_SUBDIR" MIRROR_REMOTE_SUBDIR OUT_REMOTE_SUBDIR)"

  if [[ -n "$RCLONE_REMOTE" && "$RCLONE_REMOTE" != *: ]]; then
    case "$RCLONE_REMOTE" in
      /*|./*|../*)
        ;;
      *)
        printf '%s\n' \
          "WARN: detected RCLONE_REMOTE without trailing colon: $RCLONE_REMOTE" \
          "WARN: normalizing to ${RCLONE_REMOTE}: so rclone treats it as a named remote, not a local path" \
          "WARN: base env file: $PROJECT_ENV_FILE" \
          "WARN: project env file: $REMOTE_PILOT_PROJECT_FILE" \
          "WARN: project name: $REMOTE_PILOT_PROJECT" >&2
        export RCLONE_REMOTE="${RCLONE_REMOTE}:"
        ;;
    esac
  fi

  local rclone_config_value=""
  rclone_config_value="$(first_defined_value "" "${pref}_RCLONE_CONFIG" RCLONE_CONFIG)"
  if [[ -n "$rclone_config_value" ]]; then
    export RCLONE_CONFIG="$rclone_config_value"
  else
    unset RCLONE_CONFIG
  fi
  export RCLONE_EXTRA_FLAGS="$(first_defined_value "--fast-list --transfers=8 --checkers=8" "${pref}_RCLONE_EXTRA_FLAGS" RCLONE_EXTRA_FLAGS)"

  export SLEEP_SECS="$(first_defined_value "45" "${pref}_SLEEP_SECS" SLEEP_SECS)"
  export INTERVAL_SEC="$(first_defined_value "1800" "${pref}_INTERVAL_SEC" INTERVAL_SEC)"
  export TTL_HOURS="$(first_defined_value "48" "${pref}_TTL_HOURS" TTL_HOURS)"
  export RUN_IN_BACKGROUND="$(first_defined_value "1" "${pref}_RUN_IN_BACKGROUND" RUN_IN_BACKGROUND)"
  export MAX_CONCURRENT="$(first_defined_value "1" "${pref}_MAX_CONCURRENT" MAX_CONCURRENT)"
  export COMMAND_TIMEOUT_SECS="$(first_defined_value "240" "${pref}_COMMAND_TIMEOUT_SECS" COMMAND_TIMEOUT_SECS)"
  export COMMAND_TIMEOUT_KILL_GRACE_SECS="$(first_defined_value "30" "${pref}_COMMAND_TIMEOUT_KILL_GRACE_SECS" COMMAND_TIMEOUT_KILL_GRACE_SECS)"
  export TIMEOUT_REQUEUE_TO_BG="$(first_defined_value "1" "${pref}_TIMEOUT_REQUEUE_TO_BG" TIMEOUT_REQUEUE_TO_BG)"
  export PUBLISH_LOGS="$(first_defined_value "1" "${pref}_PUBLISH_LOGS" PUBLISH_LOGS)"
  export COMMAND_SNAPSHOT_MAX_ATTEMPTS="$(first_defined_value "5" "${pref}_COMMAND_SNAPSHOT_MAX_ATTEMPTS" COMMAND_SNAPSHOT_MAX_ATTEMPTS)"
  export COMMAND_SNAPSHOT_SETTLE_SECS="$(first_defined_value "2" "${pref}_COMMAND_SNAPSHOT_SETTLE_SECS" COMMAND_SNAPSHOT_SETTLE_SECS)"

  export RELAY_LOG_FILE="$(first_defined_value "$LOG_DIR/relay.log" "${pref}_RELAY_LOG_FILE" RELAY_LOG_FILE)"
  export COMMAND_OUTPUT_LOG_FILE="$(first_defined_value "$LOG_DIR/command-output.log" "${pref}_COMMAND_OUTPUT_LOG_FILE" COMMAND_OUTPUT_LOG_FILE CMD_LOG_FILE)"
  export COMMAND_HISTORY_FILE="$(first_defined_value "$LOG_DIR/command-history.log" "${pref}_COMMAND_HISTORY_FILE" COMMAND_HISTORY_FILE)"
  export SUPERVISOR_LOG_FILE="$(first_defined_value "$LOG_DIR/supervisor.log" "${pref}_SUPERVISOR_LOG_FILE" SUPERVISOR_LOG_FILE)"
  export SYNC_LOG_FILE="$(first_defined_value "$LOG_DIR/sync.log" "${pref}_SYNC_LOG_FILE" SYNC_LOG_FILE)"
  export EMAIL_LOG_FILE="$(first_defined_value "$LOG_DIR/email.log" "${pref}_EMAIL_LOG_FILE" EMAIL_LOG_FILE)"

  export RELAY_PID_FILE="$(first_defined_value "$STATE_DIR/relay.pid" "${pref}_RELAY_PID_FILE" RELAY_PID_FILE)"
  export RELAY_LOCK_FILE="$(first_defined_value "$STATE_DIR/relay.lock" "${pref}_RELAY_LOCK_FILE" RELAY_LOCK_FILE)"
  export SUPERVISOR_LOCK_FILE="$(first_defined_value "$STATE_DIR/supervisor.lock" "${pref}_SUPERVISOR_LOCK_FILE" SUPERVISOR_LOCK_FILE)"
  export PREVIOUS_COMMAND_SCRIPT="$(first_defined_value "$STATE_DIR/commands.prev.sh" "${pref}_PREVIOUS_COMMAND_SCRIPT" PREVIOUS_COMMAND_SCRIPT)"
  export PIDS_DIR="$(first_defined_value "$STATE_DIR/relay-jobs" "${pref}_PIDS_DIR" PIDS_DIR)"
  export RCLONE_CACHE_DIR="$(first_defined_value "$STATE_DIR/rclone-cache" "${pref}_RCLONE_CACHE_DIR" RCLONE_CACHE_DIR)"

  export NOTIFIER_PASSWORD_FILE="$(first_defined_value "$HOME/.secrets/notifier_gmail_app_password" "${pref}_NOTIFIER_PASSWORD_FILE" NOTIFIER_PASSWORD_FILE)"
  if [[ -z "${SMTP_PASS:-}" && -r "$NOTIFIER_PASSWORD_FILE" ]]; then
    export SMTP_PASS="$(< "$NOTIFIER_PASSWORD_FILE")"
  fi
  export SMTP_USER="$(first_defined_value "arc.knust.job.notifier@gmail.com" "${pref}_SMTP_USER" SMTP_USER)"
  export NOTIFICATION_TO_PRIMARY="$(first_defined_value "${TO1:-}" "${pref}_NOTIFICATION_TO_PRIMARY" NOTIFICATION_TO_PRIMARY TO1)"
  export NOTIFICATION_TO_SECONDARY="$(first_defined_value "achenie@vt.edu" "${pref}_NOTIFICATION_TO_SECONDARY" NOTIFICATION_TO_SECONDARY TO2)"
  export JOB_NOTIFICATION_NAME="$(first_defined_value "$PROJECT_NAME" "${pref}_JOB_NOTIFICATION_NAME" JOB_NOTIFICATION_NAME)"
  export EMAIL_ON_START="$(first_defined_value "1" "${pref}_EMAIL_ON_START" EMAIL_ON_START)"
  export EMAIL_SENTINEL_FILE="$(first_defined_value "$STATE_DIR/.email_notifier.started.${SLURM_JOB_ID:-unknown}" "${pref}_EMAIL_SENTINEL_FILE" EMAIL_SENTINEL_FILE)"
  export FINISH_MARGIN_SECONDS="$(first_defined_value "60" "${pref}_FINISH_MARGIN_SECONDS" FINISH_MARGIN_SECONDS)"
  export EMAIL_SENTINEL_CLEANUP_DELAY_SECONDS="$(first_defined_value "30" "${pref}_EMAIL_SENTINEL_CLEANUP_DELAY_SECONDS" EMAIL_SENTINEL_CLEANUP_DELAY_SECONDS)"
  export MAIL_LOG_FILES="$(first_defined_value "slurm-${SLURM_JOB_ID:-unknown}.out $RELAY_LOG_FILE $SUPERVISOR_LOG_FILE" "${pref}_MAIL_LOG_FILES" MAIL_LOG_FILES)"
  export SLURM_TIME_TZ="$(first_defined_value "America/New_York" "${pref}_SLURM_TIME_TZ" SLURM_TIME_TZ)"
  export REPORT_TZ_ET="$(first_defined_value "America/New_York" "${pref}_REPORT_TZ_ET" REPORT_TZ_ET)"
  export REPORT_TZ_GMT="$(first_defined_value "GMT" "${pref}_REPORT_TZ_GMT" REPORT_TZ_GMT)"

  export MOUNT_IN_DIR="$COMMAND_CHANNEL_MOUNT"
  export MOUNT_FOLD_ID="$COMMAND_CHANNEL_FOLDER_ID"
  export SYNC_OUT_DIR="$MIRROR_ROOT_FOLDER_ID"
  export OUT_REMOTE="$RCLONE_REMOTE"
  export OUT_REMOTE_SUBDIR="$MIRROR_REMOTE_SUBDIR"
  export PUBLISH_LOGS_DIR="$COMMAND_CHANNEL_LOG_DIR"
  export CMD_LOG_FILE="$COMMAND_OUTPUT_LOG_FILE"
}

ensure_runtime_dirs() {
  local -a dirs=()
  local dir=""
  for dir in "$PROJECT_DIR" "$PROJECT_INSTANCE_ROOT" "$LOG_DIR" "$STATE_DIR" "$PIDS_DIR" "$RCLONE_CACHE_DIR"; do
    [[ -n "$dir" ]] && dirs+=("$dir")
  done
  mkdir -p "${dirs[@]}"
}

require_config_value() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    return 0
  fi

  cat >&2 <<EOF
Missing required setting: $name
Base env file: $PROJECT_ENV_FILE
Project env file: $REMOTE_PILOT_PROJECT_FILE
Project local override file: $REMOTE_PILOT_PROJECT_LOCAL_FILE
Project name: $REMOTE_PILOT_PROJECT
Run ./configure.sh --project "$REMOTE_PILOT_PROJECT" to create or update the project configuration.
EOF
  return 1
}

join_notification_recipients() {
  local -a recipients=()
  [[ -n "${NOTIFICATION_TO_PRIMARY:-}" ]] && recipients+=("$NOTIFICATION_TO_PRIMARY")
  [[ -n "${NOTIFICATION_TO_SECONDARY:-}" ]] && recipients+=("$NOTIFICATION_TO_SECONDARY")
  printf '%s\n' "${recipients[@]}"
}
