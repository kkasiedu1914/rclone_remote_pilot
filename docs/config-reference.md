# Config Reference

This file documents the variables exported by `lib/config.sh`.

Resolution order:

1. `.env`
2. `projects/<project>.env`
3. `projects/<project>.local.env`
4. current shell exports

## Where Configuration Lives

`projects/<project>.env` may be generated on a controller machine, but it should contain HPC/remote paths and must be committed or otherwise copied into the HPC/remote checkout before runtime scripts can load it.

`projects/<project>.local.env` is for the machine where the scripts run. In the normal remote-piloting workflow, that means the file belongs on the HPC/remote machine and stays out of git. Put host-specific paths, temporary restart/status tuning, and private runtime overrides there.

Current shell exports are also local to the shell where they are set. Exporting `SLEEP_SECS=5` on a laptop does not affect an existing relay on the HPC. Export it on the HPC/remote machine and restart `relayctl.sh` or `job_supervisor.sh` there.

## Project Selection

- `REMOTE_PILOT_PROJECT`
  Active project instance name.
- `REMOTE_PILOT_PROJECT_PREFIX`
  Normalized uppercase prefix used for tagged shell-variable lookups.
- `REMOTE_PILOT_PROJECT_ENV_DIR`
  Directory that holds per-project env files.
- `REMOTE_PILOT_PROJECT_FILE`
  Path to `projects/<project>.env`.
- `REMOTE_PILOT_PROJECT_LOCAL_FILE`
  Path to `projects/<project>.local.env`.
- `PROJECT_NAME`
  Effective project label. Defaults to `REMOTE_PILOT_PROJECT`.

## Project Paths

- `REMOTE_PILOT_HOME`
  Pilot repo root used by the script that loaded config.
- `PROJECT_ROOT`
  Same conceptual repo/project root anchor used by config loading.
- `PROJECT_DIR`
  Main working directory for commands.
- `PROJECT_INSTANCE_ROOT`
  Per-project runtime directory.
- `WORK_DIR`
  Compatibility alias for `PROJECT_DIR`.
- `SYNC_SOURCE_DIR`
  Source directory mirrored by `sync_mirror.sh`.
- `LOG_DIR`
  Local authoritative log directory.
- `STATE_DIR`
  Local state directory.
- `PIDS_DIR`
  State directory subfolder for relay background-job PID files.
- `RCLONE_CACHE_DIR`
  Cache directory used by `rclone mount`.

## Command Channel

- `REMOTE_ACCESS_EMAIL`
  Shared Drive account that should be granted folder access.
- `COMMAND_CHANNEL_MOUNT`
  Local path where the shared command folder is mounted.
- `COMMAND_CHANNEL_FOLDER_ID`
  Google Drive folder ID for the command folder.
- `COMMAND_FILE_NAME`
  Watched command filename inside the command folder.
- `COMMAND_CHANNEL_LOG_SUBDIR`
  Subdirectory used for published logs.
- `COMMAND_CHANNEL_LOG_DIR`
  Full log-publication destination.

## Mirroring

- `MIRROR_ROOT_FOLDER_ID`
  Google Drive folder ID for the mirror root.
- `RCLONE_REMOTE`
  Remote name used for Drive operations.
- `MIRROR_REMOTE_SUBDIR`
  Subdirectory under the mirror root.
- `RCLONE_CONFIG`
  Optional explicit rclone config path.
- `RCLONE_EXTRA_FLAGS`
  Extra rclone flags for transfer operations.
- `SYNC_INCLUDE_GLOBS`
  Include filters for `sync_mirror.sh`.
- `SYNC_EXCLUDES`
  Exclude filters for `sync_mirror.sh`.

## Relay Runtime

- `SLEEP_SECS`
  Poll interval for command-file changes.
- `INTERVAL_SEC`
  Supervisor loop interval.
- `TTL_HOURS`
  Relay max lifetime before clean exit.
- `RUN_IN_BACKGROUND`
  Start commands directly in the background when set to `1`.
- `MAX_CONCURRENT`
  Maximum concurrent background command runs.
- `COMMAND_TIMEOUT_SECS`
  Timeout applied to executed commands.
- `COMMAND_TIMEOUT_KILL_GRACE_SECS`
  Kill grace after timeout.
- `TIMEOUT_REQUEUE_TO_BG`
  Requeue timed-out foreground runs into background mode when `1`.
- `PUBLISH_LOGS`
  Enable log publication to the command channel when `1`.

## Logs And State Files

- `RELAY_LOG_FILE`
  Relay control log.
- `COMMAND_OUTPUT_LOG_FILE`
  Combined output transcript for executed commands.
- `COMMAND_HISTORY_FILE`
  Snapshots of command-file contents that were executed.
- `SUPERVISOR_LOG_FILE`
  Supervisor loop log.
- `SYNC_LOG_FILE`
  Mirror log.
- `EMAIL_LOG_FILE`
  Notifier log.
- `RELAY_PID_FILE`
  Relay PID file.
- `RELAY_LOCK_FILE`
  Relay lock file.
- `PREVIOUS_COMMAND_SCRIPT`
  Snapshot used to detect command-file changes.

## Notifications

- `NOTIFIER_PASSWORD_FILE`
  App-password file for SMTP auth.
- `SMTP_PASS`
  SMTP password, usually loaded from `NOTIFIER_PASSWORD_FILE`.
- `SMTP_USER`
  Sender email.
- `NOTIFICATION_TO_PRIMARY`
  Main notification recipient.
- `NOTIFICATION_TO_SECONDARY`
  Secondary notification recipient.
- `JOB_NOTIFICATION_NAME`
  Fallback Slurm job name. Defaults to `PROJECT_NAME`.
- `EMAIL_ON_START`
  Launch the notifier from the supervisor when `1`.
- `EMAIL_SENTINEL_FILE`
  Sentinel preventing duplicate notifier launch for the same job.
- `FINISH_MARGIN_SECONDS`
  Margin before walltime for cleanup.
- `MAIL_LOG_FILES`
  Space-separated list of log files tailed into notification emails. Missing entries, including unavailable Slurm stdout files, are skipped.
- `SLURM_TIME_TZ`
  Time zone used to parse Slurm timestamps.
- `REPORT_TZ_ET`
  Time zone used for ET reporting in emails.
- `REPORT_TZ_GMT`
  Time zone used for GMT reporting in emails.

## Compatibility Aliases

These aliases are exported for older wrappers:

- `MOUNT_IN_DIR`
- `MOUNT_FOLD_ID`
- `SYNC_OUT_DIR`
- `OUT_REMOTE`
- `OUT_REMOTE_SUBDIR`
- `PUBLISH_LOGS_DIR`
- `CMD_LOG_FILE`

Prefer the newer names in all new configs.
