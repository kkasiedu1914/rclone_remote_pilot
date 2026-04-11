# Remote Pilot Setup Guide

This guide assumes one person owns the Google Drive folders and one or more remote machines will mount the command channel and write results back to a shared mirror location.

The refactored model supports multiple named project instances on the same system. One shared code copy of `rclone_remote_pilot` can manage many separate projects, and each project gets its own config and runtime state.

The default Google Drive account to grant access to is:

```text
compucatalysis@gmail.com
```

## 1. Create the shared Drive folders

From the owner account in Google Drive:

1. Create a parent folder, for example `remote-pilot`.
2. Inside it create:
   - `command-channel`
   - `mirror-root`
3. Share both folders with `compucatalysis@gmail.com`.
4. Give that account at least `Editor` access.

Why two folders:

- `command-channel` is where the remote machine looks for `commands.sh`.
- `command-channel/logs` is where the relay republishes logs so the controller can inspect status.
- `mirror-root` is where the remote machine syncs outputs, checkpoints, reports, or other artifacts.

## 2. Capture the folder IDs

Open each shared folder in Google Drive and copy the folder ID from the URL.

You need:

- `COMMAND_CHANNEL_FOLDER_ID` for `command-channel`
- `MIRROR_ROOT_FOLDER_ID` for `mirror-root`

## 3. Prepare the remote machine

Install the required tools on the machine that will run the relay:

```bash
sudo apt-get update
sudo apt-get install -y rclone fuse3
python3 --version
```

If you are on HPC, install or load whatever provides:

- `rclone`
- `fusermount`
- `python3`
- optionally `squeue` and `sacct` for Slurm supervision

## 4. Configure rclone

Authenticate `rclone` against the Google Drive account that has access to the shared folders:

```bash
rclone config
rclone lsd gdrive:
```

Use a different remote name if needed; store that in config later.

## 5. Configure one project instance

From the pilot directory:

```bash
cd /home/kkasiedu/projects/rclone_remote_pilot
chmod +x *.sh
./configure.sh --project my_project
export REMOTE_PILOT_PROJECT=my_project
```

`configure.sh --project my_project` writes:

```text
projects/my_project.env
```

That file is intended to be committed with the project repo so the user can generate it locally, push it, and let the HPC side pull it.

Optional machine-only overrides can go in:

```text
projects/my_project.local.env
```

That local override file stays ignored by git.

Important prompts:

- `Main project directory on the remote system`
  - example: `/scratch/alice/project_a`
- `Google Drive folder ID for the shared command channel`
- `Google Drive folder ID for the shared mirror root`
- `Local mount point for the command channel`
  - example: `$HOME/remote-pilot/my_project/command-channel`
- `Mirror subdirectory name for this machine`
  - example: `my_project/node-a`
- `SMTP_USER`
  - default: `arc.knust.job.notifier@gmail.com`
- `NOTIFICATION_TO_PRIMARY`
  - no default; the user should set this
- `NOTIFICATION_TO_SECONDARY`
  - default: `achenie@vt.edu`
- `NOTIFIER_PASSWORD_FILE`
  - default: `$HOME/.secrets/remote_pilot_gmail_app_password`

For ARC / VT-style usage, the sender and VT secondary recipient already default to the original values. The user mainly needs to set the primary recipient and make sure the password file exists on the HPC.

## 6. Understand the config resolution

The scripts load configuration in this order:

1. `.env` for global defaults
2. `projects/<REMOTE_PILOT_PROJECT>.env` for the selected project
3. `projects/<REMOTE_PILOT_PROJECT>.local.env` for machine-only overrides
4. optional tagged shell variables such as `PROJECT_A_PROJECT_DIR=...`

This means one shared installation can serve many users or many projects.

Tagged shell variables are optional. Example:

```bash
export REMOTE_PILOT_PROJECT=project_a
export PROJECT_A_PROJECT_DIR=/scratch/alice/project_a
export PROJECT_A_COMMAND_CHANNEL_FOLDER_ID=abc123
export PROJECT_A_MIRROR_ROOT_FOLDER_ID=xyz456
```

The per-project env files are usually the cleaner default.

## 7. Runtime layout

For a selected project instance:

- workload code lives in `PROJECT_DIR`
- runtime files live in `<PROJECT_DIR>/.remote-pilot/<project-name>/`
- logs live in `<PROJECT_DIR>/.remote-pilot/<project-name>/logs/`
- state files live in `<PROJECT_DIR>/.remote-pilot/<project-name>/state/`

Remote Google Drive layout:

- `command-channel/commands.sh`
- `command-channel/logs/`
- `mirror-root/<project-name>/<machine-subdir>/`

## 8. Start the relay

```bash
./relayctl.sh start
./relayctl.sh status
```

What happens:

1. The active project is selected from `REMOTE_PILOT_PROJECT`.
2. The relay loads that project’s config file.
3. The relay mounts the shared command channel if needed.
4. It watches `commands.sh`.
5. When `commands.sh` changes, it copies a snapshot locally and runs it from `PROJECT_DIR`.
6. It republishes logs to `command-channel/logs/`.

Because the relay auto-`cd`s into `PROJECT_DIR`, commands run in the actual workload project by default.

## 9. First command test

Put this file in the shared `command-channel` folder as `commands.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "remote pilot test ok"
hostname
pwd
date -Is
```

Expected result:

- `pwd` prints the configured `PROJECT_DIR`
- output appears in `<PROJECT_DIR>/.remote-pilot/<project-name>/logs/command-output.log`
- relay logs appear in `command-channel/logs/`

## 10. Mirror results back to Drive

The command channel is only for commands and logs. Output mirroring is separate:

```bash
./sync_mirror.sh
```

This syncs `SYNC_SOURCE_DIR`, which defaults to `PROJECT_DIR`, to:

```text
<RCLONE_REMOTE>/<MIRROR_REMOTE_SUBDIR>
```

under the Drive root folder specified by `MIRROR_ROOT_FOLDER_ID`.

## 11. Slurm / HPC mode

If you want a watchdog that keeps the relay alive during a Slurm job, use:

```bash
./job_supervisor.sh
```

Optional notification setup:

```bash
mkdir -p ~/.secrets
chmod 700 ~/.secrets
printf '%s\n' 'your-app-password' > ~/.secrets/remote_pilot_gmail_app_password
chmod 600 ~/.secrets/remote_pilot_gmail_app_password
```

Then set:

- `SMTP_USER`
  - can usually be left at the default `arc.knust.job.notifier@gmail.com`
- `NOTIFICATION_TO_PRIMARY`
  - should be set by the user
- optionally `NOTIFICATION_TO_SECONDARY`
  - can usually be left at the default `achenie@vt.edu`
- `NOTIFIER_PASSWORD_FILE`

## 12. Shared-Code Multi-User Example

One shared pilot installation on HPC:

```text
/opt/rclone_remote_pilot
```

Two separate user or project directories:

```text
/scratch/alice/project_a
/scratch/bob/project_b
```

Project A:

```bash
cd /opt/rclone_remote_pilot
./configure.sh --project project_a
export REMOTE_PILOT_PROJECT=project_a
./relayctl.sh start
```

Project B:

```bash
cd /opt/rclone_remote_pilot
./configure.sh --project project_b
export REMOTE_PILOT_PROJECT=project_b
./relayctl.sh start
```

Each project instance gets:

- its own project directory
- its own command channel
- its own mirror destination or mirror subdirectory
- its own mount point
- its own runtime state directory

## 13. Compatibility wrappers

The old project-specific names still work, but they now forward to the generic scripts:

- `start_kk_job.sh` -> `relayctl.sh`
- `kkremote.sh` -> `job_supervisor.sh`
- `gsync.sh` -> `sync_mirror.sh`
- `fixer.sh` -> `repair_mount.sh`
- `email.sh` -> `job_notifier.sh`

## 14. Troubleshooting

If the relay cannot mount the command folder:

```bash
./repair_mount.sh
./relayctl.sh restart
```

If commands run from the wrong place:

1. Check `REMOTE_PILOT_PROJECT`
2. Check `projects/<project>.env`
3. Confirm `PROJECT_DIR` is correct

If mirroring fails:

1. Confirm `MIRROR_ROOT_FOLDER_ID` is correct
2. Confirm the Drive account behind `RCLONE_REMOTE` can write there
3. Check the per-project sync log under `.remote-pilot/<project>/logs/`
