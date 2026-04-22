# Quick Setup

Use this when you already understand the shared-folder model. For the full walkthrough, read [SETUP.md](./SETUP.md).

This tool remote-pilots an HPC, lab server, cloud VM, or other remote Linux desktop. Treat the user's laptop/workstation as the controller machine and the HPC/remote desktop as the runtime machine.

## 1. Configure Drive access

Share these two Google Drive folders with:

```text
compucatalysis@gmail.com
```

- `command-channel`
- `mirror-root`

Copy both folder IDs from Google Drive.

## 2. Configure one project instance from the controller side

```bash
cd /home/kkasiedu/projects/rclone_remote_pilot
chmod +x *.sh
./configure.sh --project my_project
```

Enter HPC/remote paths when prompted, even if you run `configure.sh` locally. The generated `projects/my_project.env` is a control file for the remote machine: review it, commit it, push it, and pull it into the HPC/remote checkout before starting the relay.

Defaults during setup:

- `SMTP_USER=arc.knust.job.notifier@gmail.com`
- `NOTIFICATION_TO_SECONDARY=achenie@vt.edu`
- `NOTIFICATION_TO_PRIMARY` should be filled in by the user

## 3. Prepare and start on the HPC/remote machine

On the HPC/remote machine, configure or load the `rclone` remote that can access the shared folders, then run:

```bash
rclone config
rclone lsd gdrive:
cd /path/to/project-or-tool/rclone_remote_pilot
export REMOTE_PILOT_PROJECT=my_project
./relayctl.sh start
./relayctl.sh status
```

## 4. Test with a command file

Create or edit `commands.sh` in the shared `command-channel` folder. You may edit it from the controller side, but every line runs on the HPC/remote machine from the configured `PROJECT_DIR`, so use HPC/remote paths:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "remote pilot test ok"
hostname
pwd
date -Is
```

`pwd` should print the configured `PROJECT_DIR` for the selected project instance.

## 5. Mirror outputs

```bash
./sync_mirror.sh
```

This mirrors the configured project directory, not the pilot code directory.

## 6. HPC mode

```bash
./job_supervisor.sh
```

Optional notifier password file:

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s\n' 'your-app-password' > ~/.secrets/remote_pilot_gmail_app_password
chmod 600 ~/.secrets/remote_pilot_gmail_app_password
```

Any runtime tuning that controls restart/status behavior, such as `SLEEP_SECS`, `INTERVAL_SEC`, `RUN_IN_BACKGROUND`, or `COMMAND_FILE_NAME`, must be exported on the HPC/remote machine before restarting the relay or saved in `projects/my_project.local.env` on that machine.
