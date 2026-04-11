# Quick Setup

Use this when you already understand the shared-folder model. For the full walkthrough, read [SETUP.md](./SETUP.md).

## 1. Configure Drive access

Share these two Google Drive folders with:

```text
compucatalysis@gmail.com
```

- `command-channel`
- `mirror-root`

Copy both folder IDs from Google Drive.

## 2. Configure rclone and one project instance

```bash
cd /home/kkasiedu/projects/rclone_remote_pilot
chmod +x *.sh
rclone config
./configure.sh --project my_project
export REMOTE_PILOT_PROJECT=my_project
```

Defaults during setup:

- `SMTP_USER=arc.knust.job.notifier@gmail.com`
- `NOTIFICATION_TO_SECONDARY=achenie@vt.edu`
- `NOTIFICATION_TO_PRIMARY` should be filled in by the user

## 3. Start the relay

```bash
./relayctl.sh start
./relayctl.sh status
```

## 4. Test with a command file

Create `commands.sh` in the shared `command-channel` folder:

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
