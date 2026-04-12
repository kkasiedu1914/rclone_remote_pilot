# rclone_remote_pilot

`rclone_remote_pilot` is a command relay for running work on a remote Linux or HPC project through a shared Google Drive folder.

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

Compatibility wrappers are still available:

- `start_kk_job.sh`
- `kkremote.sh`
- `gsync.sh`
- `fixer.sh`
- `email.sh`

## Configuration Model

Configuration is layered:

- optional global defaults in `.env`
- committed per-project config in `projects/<project-name>.env`
- optional machine-only overrides in `projects/<project-name>.local.env`
- optional tagged shell variables such as `PROJECT_A_PROJECT_DIR=...`

The active project instance is selected with:

```bash
export REMOTE_PILOT_PROJECT=my_project
```

Create or update that project instance with:

```bash
./configure.sh --project my_project
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
- `monitor_gpu_restart.sh` is not required for the core relay workflow.
