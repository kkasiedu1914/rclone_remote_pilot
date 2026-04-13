# rclone_remote_pilot

`rclone_remote_pilot` is a command relay for running work on a remote Linux or HPC project through a shared Google Drive folder.

Reference docs live in `docs/`:

- `docs/architecture.md`
- `docs/config-reference.md`
- `docs/operations.md`

It is designed for this workflow:

1. The user configures the pilot locally with the HPC paths in mind.
2. The generated project config file is committed with the project repo.
3. The HPC side pulls the repo.
4. The HPC operator selects the project instance and starts either:
   - the plain relay
   - the Slurm job supervisor with start and finish email notifications

## What It Does

- mounts a shared Google Drive command folder with `rclone mount`
- watches a configurable command file such as `commands.sh`
- auto-creates that watched command file if it is missing
- runs command scripts from the configured `PROJECT_DIR`
- republishes logs back into the shared command folder
- mirrors project outputs to a separate shared Drive folder
- optionally supervises the relay inside a Slurm job
- optionally sends start and finish email notifications for Slurm jobs

## Main Scripts

- `configure.sh`
  Creates global defaults or a named project config.
- `relayctl.sh`
  Starts, stops, restarts, or checks the relay.
- `relay.sh`
  The core command polling and execution loop.
- `sync_mirror.sh`
  Pushes project outputs back to Drive.
- `job_supervisor.sh`
  Slurm/HPC watchdog that also launches email notifications.
- `job_notifier.sh`
  Sends start and finish emails from inside a Slurm job.
- `repair_mount.sh`
  Cleans up a broken or stale mount.

Legacy wrappers and older reference material are in `legacy/`:

- `legacy/start_kk_job.sh`
- `legacy/kkremote.sh`
- `legacy/gsync.sh`
- `legacy/fixer.sh`
- `legacy/email.sh`
- `legacy/monitor_gpu_restart.sh`
- `legacy/VT remote piloting system.md`

For new use, prefer the top-level generic scripts only.

## Configuration Model

Configuration is layered:

- optional global defaults in `.env`
- committed per-project config in `projects/<project-name>.env`
- optional machine-only overrides in `projects/<project-name>.local.env`
- optional tagged shell variables such as `PROJECT_A_PROJECT_DIR=...`

Later layers win over earlier ones. In practice:

1. `.env`
2. `projects/<project>.env`
3. `projects/<project>.local.env`
4. shell exports in the current session

The active project instance is selected with:

```bash
export REMOTE_PILOT_PROJECT=my_project
```

Create or update that project instance with:

```bash
./configure.sh --project my_project
```

This means a user can keep committed project defaults in git, but still override selected values on the HPC before launch, for example:

```bash
export REMOTE_PILOT_PROJECT=my_project
export SLEEP_SECS=5
export INTERVAL_SEC=60
export RUN_IN_BACKGROUND=0
bash rclone_remote_pilot/relayctl.sh start
```

## KNUST / ARC Defaults

These defaults are already built in for the workflow we discussed:

- shared Google Drive access email:
  `compucatalysis@gmail.com`
- default SMTP sender:
  `arc.knust.job.notifier@gmail.com`
- default secondary recipient:
  `achenie@vt.edu`

What the user should normally set:

- `NOTIFICATION_TO_PRIMARY`
- `PROJECT_DIR`
- `COMMAND_CHANNEL_FOLDER_ID`
- `MIRROR_ROOT_FOLDER_ID`
- `COMMAND_CHANNEL_MOUNT`
- `MIRROR_REMOTE_SUBDIR`
- `NOTIFIER_PASSWORD_FILE`

Useful tuning knobs that can now be set during `./configure.sh --project ...`:

- `SLEEP_SECS`
  Relay polling interval for checking command-file changes.
- `INTERVAL_SEC`
  Supervisor restart-check interval inside `job_supervisor.sh`.
- `TTL_HOURS`
  Maximum relay lifetime before clean exit.
- `RUN_IN_BACKGROUND`
  Whether commands execute asynchronously.
- `MAX_CONCURRENT`
  Maximum number of concurrent command runs.
- `COMMAND_TIMEOUT_SECS`
  Per-command timeout. `0` disables the timeout.
- `COMMAND_TIMEOUT_KILL_GRACE_SECS`
  Grace period before SIGKILL after timeout.
- `PUBLISH_LOGS`
  Whether logs are copied back to the shared command folder.
- `EMAIL_ON_START`
  Whether `job_supervisor.sh` auto-launches `job_notifier.sh`.
- `FINISH_MARGIN_SECONDS`
  Margin before walltime for cleanup / final handling.

## Configurable Parameters

The parameters below are the ones most users are likely to adjust. They can be grouped into:

- project identity and paths
- command-channel behavior
- relay runtime behavior
- mirroring behavior
- notifications and reporting

### Project Identity And Paths

- `PROJECT_NAME`
  Active project label. Usually matches `REMOTE_PILOT_PROJECT`.
- `PROJECT_DIR`
  Main project directory on the remote system. Commands run from here by default.
- `PROJECT_INSTANCE_ROOT`
  Per-project runtime root. Defaults to `PROJECT_DIR/.remote-pilot/<project>`.
- `LOG_DIR`
  Local authoritative log directory.
- `STATE_DIR`
  Local runtime state directory.

### Command Channel

- `REMOTE_ACCESS_EMAIL`
  Drive account that should be granted access to the shared command and mirror folders.
- `RCLONE_REMOTE`
  The configured `rclone` remote name, such as `gdrive:` or `gdriveN:`.
- `RCLONE_CONFIG`
  Optional explicit path to an `rclone` config file. Leave unset to use the normal `rclone` config discovery path.
- `COMMAND_CHANNEL_FOLDER_ID`
  Google Drive folder ID for the shared command folder.
- `COMMAND_CHANNEL_MOUNT`
  Local mount path for that shared command folder.
- `COMMAND_FILE_NAME`
  File the relay watches inside the mounted command folder. Default is `commands.sh`.
- `COMMAND_CHANNEL_LOG_SUBDIR`
  Subdirectory under the mounted command folder where published logs go. Default is `logs`.
- `COMMAND_CHANNEL_LOG_DIR`
  Full publish destination for relay and supervisor logs. Defaults to `COMMAND_CHANNEL_MOUNT/logs`.

### Relay Runtime

- `SLEEP_SECS`
  Poll interval for command-file changes.
- `TTL_HOURS`
  Maximum lifetime of a relay process before it exits cleanly.
- `RUN_IN_BACKGROUND`
  If `1`, commands start in the background immediately. If `0`, commands start in the foreground first.
- `MAX_CONCURRENT`
  Maximum simultaneous command executions.
- `COMMAND_TIMEOUT_SECS`
  Foreground timeout for a command run. `0` disables the timeout.
- `COMMAND_TIMEOUT_KILL_GRACE_SECS`
  Grace period before SIGKILL after a timeout.
- `TIMEOUT_REQUEUE_TO_BG`
  If `1`, a timed-out foreground command is relaunched in the background.
- `PUBLISH_LOGS`
  If `1`, the relay republishes local log files into the mounted command folder.

### Mirror Behavior

- `MIRROR_ROOT_FOLDER_ID`
  Google Drive folder ID that acts as the root of the mirror destination.
- `MIRROR_REMOTE_SUBDIR`
  Project-specific subdirectory under the mirror root.
- `SYNC_SOURCE_DIR`
  Local source directory mirrored to Drive. Defaults to `PROJECT_DIR`.
- `RCLONE_EXTRA_FLAGS`
  Extra `rclone` transfer flags, such as `--fast-list --transfers=8 --checkers=8`.
- `SYNC_INCLUDE_GLOBS`
  Include filters for the mirror sync.
- `SYNC_EXCLUDES`
  Exclude filters for the mirror sync. By default `.remote-pilot/**` is excluded so runtime state is not mirrored.

Users can override these before running `sync_mirror.sh`, for example:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export SYNC_INCLUDE_GLOBS="outputs/** checkpoints/** reports/** *.csv *.txt"
export SYNC_EXCLUDES=".git/** .remote-pilot/** checkpoints/tmp/** *.tmp"
export RCLONE_EXTRA_FLAGS="--fast-list --transfers=16 --checkers=16"
bash rclone_remote_pilot/sync_mirror.sh
```

### Supervisor And Notifications

- `INTERVAL_SEC`
  How often `job_supervisor.sh` performs a restart/health-check cycle.
- `SMTP_USER`
  Sender account for notifications.
- `NOTIFIER_PASSWORD_FILE`
  Path to the Gmail app-password file on the remote machine.
- `NOTIFICATION_TO_PRIMARY`
  Main recipient for job notifications.
- `NOTIFICATION_TO_SECONDARY`
  Secondary recipient. Default is `achenie@vt.edu`.
- `JOB_NOTIFICATION_NAME`
  Fallback Slurm job name used when `SLURM_JOB_NAME` is unset. By default this now falls back to `PROJECT_NAME`.
- `EMAIL_ON_START`
  If `1`, the supervisor launches the notifier once per job.
- `MAIL_LOG_FILES`
  Space-separated list of files whose tails are attached in start/finish notification emails. By default this now includes the Slurm stdout file plus the current relay and supervisor logs.
- `FINISH_MARGIN_SECONDS`
  Time-before-walltime margin for final cleanup behavior.
- `SLURM_TIME_TZ`
  Time zone assumed when parsing Slurm timestamps.
- `REPORT_TZ_ET`
  Time zone used for the "ET" section in emails.
- `REPORT_TZ_GMT`
  Time zone used for the "GMT" section in emails.

### Legacy Compatibility Aliases

The loader still supports several old variable names for compatibility:

- `MOUNT_IN_DIR`
- `MOUNT_FOLD_ID`
- `SYNC_OUT_DIR`
- `OUT_REMOTE`
- `OUT_REMOTE_SUBDIR`
- `PUBLISH_LOGS_DIR`
- `CMD_LOG_FILE`

For new setups, prefer the newer names documented above. Old aliases can make debugging harder if both styles appear in the same config.

## When Changes Take Effect

Some settings are read only when a script starts, while others matter only for new supervisor or relay launches.

- Requires relay restart:
  `COMMAND_CHANNEL_MOUNT`, `COMMAND_FILE_NAME`, `COMMAND_CHANNEL_LOG_DIR`, `SLEEP_SECS`, `RUN_IN_BACKGROUND`, `MAX_CONCURRENT`, `COMMAND_TIMEOUT_SECS`, `COMMAND_TIMEOUT_KILL_GRACE_SECS`, `PUBLISH_LOGS`, `RCLONE_REMOTE`, `RCLONE_CONFIG`
- Requires rerunning `sync_mirror.sh`:
  `SYNC_SOURCE_DIR`, `MIRROR_ROOT_FOLDER_ID`, `MIRROR_REMOTE_SUBDIR`, `SYNC_INCLUDE_GLOBS`, `SYNC_EXCLUDES`, `RCLONE_EXTRA_FLAGS`
- Requires relaunching `job_supervisor.sh`:
  `INTERVAL_SEC`, `EMAIL_ON_START`, `FINISH_MARGIN_SECONDS`, `JOB_NOTIFICATION_NAME`, `MAIL_LOG_FILES`
- Requires relaunching `job_notifier.sh` or a new Slurm job:
  `SMTP_USER`, `NOTIFIER_PASSWORD_FILE`, `NOTIFICATION_TO_PRIMARY`, `NOTIFICATION_TO_SECONDARY`, `SLURM_TIME_TZ`, `REPORT_TZ_ET`, `REPORT_TZ_GMT`

In short: after changing runtime shell exports, restart the relay or supervisor so the new values are loaded cleanly.

## Common Session Overrides

These are useful when the user wants temporary behavior changes on the HPC without editing the committed project config:

Fast command turnaround:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export SLEEP_SECS=5
bash rclone_remote_pilot/relayctl.sh restart
```

Foreground-first execution with timeout fallback:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export RUN_IN_BACKGROUND=0
export COMMAND_TIMEOUT_SECS=240
export TIMEOUT_REQUEUE_TO_BG=1
bash rclone_remote_pilot/relayctl.sh restart
```

Frequent supervisor checks during debugging:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export INTERVAL_SEC=60
bash rclone_remote_pilot/job_supervisor.sh
```

Disable published logs temporarily:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export PUBLISH_LOGS=0
bash rclone_remote_pilot/relayctl.sh restart
```

Use a different command filename for one session:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export COMMAND_FILE_NAME=achenie.sh
bash rclone_remote_pilot/relayctl.sh restart
```

Change mirror filters for one sync run:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export SYNC_INCLUDE_GLOBS="outputs/** artifacts/** *.csv *.parquet"
export SYNC_EXCLUDES=".git/** .remote-pilot/** artifacts/tmp/**"
export RCLONE_EXTRA_FLAGS="--fast-list --transfers=16 --checkers=16"
bash rclone_remote_pilot/sync_mirror.sh
```

## Secrets Note

Do not commit the actual Gmail app password.

What should be committed:

- the path to the password file, for example:
  `NOTIFIER_PASSWORD_FILE=/home/achenie/.secrets/notifier_gmail_app_password`

What must already exist on the HPC:

- the password file itself

Example HPC setup:

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s\n' 'your-app-password' > ~/.secrets/notifier_gmail_app_password
chmod 600 ~/.secrets/notifier_gmail_app_password
```

## Step-By-Step Example

This example follows the exact workflow we settled on.

Assumptions:

- project name: `demo_project`
- remote name: `gdriveN:`
- HPC project directory:
  `/home/achenie/KNUST_Student_Projects/kkasiedu/remote_pilot_demo_project`
- command channel mount:
  `/home/achenie/KNUST_Student_Projects/kkasiedu/commands-channel`
- command file name:
  `commands.sh`
- mirror subdirectory:
  `test-project`

### 1. User creates shared Drive folders

In Google Drive:

1. Create a `command-channel` folder.
2. Create a `mirror-root` folder.
3. Share both with:
   `compucatalysis@gmail.com`
4. Copy both folder IDs.

### 2. User configures the project locally

From inside the pilot directory:

```bash
cd rclone_remote_pilot
./configure.sh --project demo_project
```

Example answers:

```text
Google Drive email to grant access to the shared folders [compucatalysis@gmail.com]:
rclone remote name for that Drive account [gdrive:]: gdriveN:
Main project directory on the remote system [...]: /home/achenie/KNUST_Student_Projects/kkasiedu/remote_pilot_demo_project
Google Drive folder ID for the shared command channel: 1Dc0-H8QV2CVPUPSd6_Q4hNTrauBK565T
Google Drive folder ID for the shared mirror root: 1Bsk2Aq_qwFDmqS8HVL2lq7EufU2MnTyV
Local mount point for the command channel [...]: /home/achenie/KNUST_Student_Projects/kkasiedu/commands-channel
Command file name to watch [commands.sh]:
Mirror subdirectory name for this machine [...]: test-project
SMTP sender email for optional job notifications [arc.knust.job.notifier@gmail.com]:
Primary notification recipient (required if using email): korantengkwabenaasiedu@gmail.com
Secondary notification recipient [achenie@vt.edu]:
Password file for SMTP app password [...]: /home/achenie/.secrets/notifier_gmail_app_password

Advanced runtime tuning
Relay poll interval in seconds [45]:
Supervisor restart-check interval in seconds [1800]:
Relay TTL in hours [48]:
Run commands in background (1=yes, 0=no) [1]:
Maximum concurrent command runs [1]:
Command timeout in seconds (0 disables) [240]:
Timeout kill grace in seconds [30]:
Publish logs back to the command channel (1=yes, 0=no) [1]:
Auto-start email notifier inside Slurm jobs (1=yes, 0=no) [1]:
Seconds before walltime to stop relay / send final handling [60]:
```

If you press Enter on a prompt with square brackets, that default is used.

Examples:

- set `SLEEP_SECS=5` if you want the relay to detect command changes much faster
- keep `SLEEP_SECS=45` if lower polling overhead matters more than response speed
- set `INTERVAL_SEC=300` if you want the Slurm supervisor to check the relay every 5 minutes instead of every 30 minutes

This writes:

```text
projects/demo_project.env
```

### 3. User reviews and commits the generated project config

The file to review is:

```text
projects/demo_project.env
```

Commit it with the repo:

```bash
git add projects/demo_project.env
git commit -m "Add remote pilot config for demo_project"
git push
```

### 4. HPC side pulls the project repo

On HPC:

```bash
cd /home/achenie/KNUST_Student_Projects/kkasiedu/remote_pilot_demo_project
git pull
cd rclone_remote_pilot
```

### 5. HPC side selects the project instance

```bash
export REMOTE_PILOT_PROJECT=demo_project
```

### 6. HPC side verifies rclone access

```bash
rclone lsd gdriveN:
```

### 7. Plain relay start

```bash
./relayctl.sh start
./relayctl.sh status
```

When the relay starts:

- runtime directories are created under:
  `<PROJECT_DIR>/.remote-pilot/demo_project/`
- the command channel mount directory is created if needed
- the watched command file is created if it does not already exist

For this example, that means the relay will ensure:

```text
/home/achenie/KNUST_Student_Projects/kkasiedu/commands-channel/commands.sh
```

exists, even if it starts empty.

### 8. User sends a test command

Put this into the shared command file:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "remote pilot test ok"
hostname
pwd
date -Is
```

Expected behavior:

- the relay detects the change
- the script is executed from `PROJECT_DIR`
- `pwd` prints the configured HPC project path
- logs appear in the command-channel logs folder

### 8a. `commands.sh` patterns

The shared command file can be as simple or as detailed as you want. The relay only cares that it is an executable shell script. You can:

- write everything to the standard `command-output.log`
- also append your own summary lines to a small `cmd.log`
- create separate log files for long-running background processes so the main command log stays readable

Simple foreground example:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "starting quick diagnostic"
hostname
pwd
python -V
date -Is
```

Foreground example with a compact custom `cmd.log`:

```bash
#!/usr/bin/env bash
set -u
set +e
set -o pipefail

echo "Status: beginning training run $(date -Is)" >> cmd.log 2>&1
cd /home/achenie/KNUST_Student_Projects/kkasiedu/remote_pilot_demo_project || exit 1

python src/train.py configs/demo_config.json >> train.stdout.log 2>&1
echo "Status: training finished $(date -Is)" >> cmd.log 2>&1

cp -f cmd.log "$COMMAND_CHANNEL_MOUNT/logs/" 2>/dev/null || true
```

Background-process example with separate logs:

```bash
#!/usr/bin/env bash
set -u
set +e
set -o pipefail

echo "Status: launching background worker $(date -Is)" >> cmd.log 2>&1
cd /home/achenie/KNUST_Student_Projects/kkasiedu/remote_pilot_demo_project || exit 1

nohup python src/train.py configs/demo_config.json \
  >> outputs/train_worker.log 2>&1 &

worker_pid=$!
echo "Status: worker pid=$worker_pid" >> cmd.log 2>&1
echo "$worker_pid" > outputs/train_worker.pid

cp -f cmd.log "$COMMAND_CHANNEL_MOUNT/logs/" 2>/dev/null || true
```

Recommended practice:

- let the relay-managed `command-output.log` capture the full shell transcript
- use `cmd.log` only for short status lines if you want a cleaner summary
- send especially noisy or long-running processes to dedicated log files such as `train.stdout.log` or `outputs/train_worker.log`
- keep custom logs inside the project directory if you want them to be picked up by `sync_mirror.sh`

### 8b. Sending files to the remote machine

There are two common patterns for moving files into the remote environment:

- send small control files or helper scripts through the mounted command folder
- send large datasets or model artifacts through a separate storage backend such as Google Cloud Storage

Small-file example through the mounted command folder:

```bash
#!/usr/bin/env bash
set -euo pipefail

cp configs/new_run.yaml "$COMMAND_CHANNEL_MOUNT/new_run.yaml"
echo "uploaded new_run.yaml into command channel"
```

That pattern is fine for small helper files, notes, or configs. It is not the best choice for large datasets or large checkpoints.

Large-file example using a separate bucket or remote:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Example only: configure the remote or bucket separately first.
rclone copy outputs/checkpoint.pt gcs:my-remote-pilot-bucket/demo_project/
```

or, if your system provides `gsutil`:

```bash
#!/usr/bin/env bash
set -euo pipefail

gsutil cp outputs/checkpoint.pt gs://my-remote-pilot-bucket/demo_project/
```

Recommended rule:

- use the mounted command folder for commands, small configs, and lightweight control artifacts
- use `sync_mirror.sh` for routine project-result mirroring
- use a bucket or separate object-storage remote for especially large files, datasets, or checkpoints

The remote pilot system does not configure Google Cloud Storage automatically. If you want to use a GCS bucket, configure that separately on the remote machine with either:

- an `rclone` remote such as `gcs:`
- `gsutil`
- another storage client available on your system

Once configured, those commands can be called directly from `commands.sh` just like any other shell command.

### 9. Mirror outputs

On HPC:

```bash
./sync_mirror.sh
```

This mirrors the configured `PROJECT_DIR` by default.

### 10. Slurm job monitoring with email

Inside a Slurm job:

```bash
export REMOTE_PILOT_PROJECT=demo_project
./job_supervisor.sh
```

What happens:

- the relay is restarted if needed
- `job_notifier.sh` is launched once for the job
- a STARTED email is sent
- a FINISHED email is sent when Slurm records the final state

## Important Runtime Notes

- `configure.sh` stores remote HPC paths as configuration only.
- `configure.sh` does not create the remote HPC project or mount directories during local setup.
- runtime scripts create writable runtime directories on the machine where the relay actually runs.
- the secret password file itself is expected to already exist on the HPC.

## Typical Day-To-Day Commands

Select a project:

```bash
export REMOTE_PILOT_PROJECT=demo_project
```

Start relay:

```bash
./relayctl.sh start
```

Check status:

```bash
./relayctl.sh status
```

Restart relay:

```bash
./relayctl.sh restart
```

Stop relay:

```bash
./relayctl.sh stop
```

Run mirror:

```bash
./sync_mirror.sh
```

Run Slurm monitoring:

```bash
./job_supervisor.sh
```

## Related Docs

- [SETUP.md](./SETUP.md)
- [QUICK_SETUP.md](./QUICK_SETUP.md)

## Notes

- `send_email.py` is the SMTP helper used by `job_notifier.sh`.
- `legacy/monitor_gpu_restart.sh` is not required for the core relay workflow.
