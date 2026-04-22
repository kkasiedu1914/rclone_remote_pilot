# Architecture

## Purpose

`rclone_remote_pilot` is a control-plane toolkit for remote-piloting an HPC, lab server, cloud VM, or other remote Linux desktop through a shared Google Drive command folder.

The system separates:

- command transport
- remote-side execution
- log publication
- output mirroring
- optional Slurm supervision and notifications

The controller machine prepares and edits control inputs. The HPC/remote machine runs the relay, mounts the shared command channel, executes command snapshots from `PROJECT_DIR`, supervises restarts, sends notifications, and mirrors outputs.

## Main Components

- `configure.sh`
  Writes `.env` or `projects/<project>.env`.
- `lib/config.sh`
  Loads configuration and exports the runtime variables used by every script.
- `relayctl.sh`
  Starts, stops, restarts, and checks the relay process.
- `relay.sh`
  Mounts the command folder, watches the command file, executes commands, and republishes logs.
- `sync_mirror.sh`
  Mirrors selected project files back to the configured remote destination.
- `job_supervisor.sh`
  Runs a restart/health loop, repairs bad mounts, and launches the notifier once per Slurm job.
- `job_notifier.sh`
  Sends STARTED and FINISHED emails for Slurm jobs, or a standalone project-start summary when Slurm is unavailable.
- `repair_mount.sh`
  Force-resets a stale or broken mount path.
- `mount_utils.sh`
  Shared helpers for mount responsiveness and mount-related PID lookup.

## Runtime Layout

The active project is selected with:

```bash
export REMOTE_PILOT_PROJECT=my_project
```

The runtime layout defaults to:

```text
PROJECT_DIR/
  .remote-pilot/
    <project>/
      logs/
      state/
```

Important directories:

- `PROJECT_DIR`
  Working directory for executed commands.
- `PROJECT_INSTANCE_ROOT`
  Per-project runtime root.
- `LOG_DIR`
  Local authoritative logs.
- `STATE_DIR`
  PID files, lock files, previous-command snapshots, notifier sentinels, relay temp state.
- `COMMAND_CHANNEL_MOUNT`
  Mounted shared Drive command folder.

## Control Flow

### Relay

1. `relayctl.sh start` loads config.
2. `relay.sh` starts and acquires the relay lock.
3. The relay ensures the command-channel mount is healthy.
4. If the watched command file does not exist, the relay logs a warning and waits for the user to create it in the shared Drive folder.
5. The relay polls for command-file changes.
6. On change, the relay snapshots the command file into `STATE_DIR`.
7. The relay executes that snapshot from `PROJECT_DIR`.
8. The relay writes logs locally into `LOG_DIR`.
9. If `PUBLISH_LOGS=1`, the relay copies standard logs to `COMMAND_CHANNEL_LOG_DIR`.

### Mirror

1. `sync_mirror.sh` loads config.
2. It resolves `SYNC_SOURCE_DIR`, include globs, exclude globs, and `RCLONE_EXTRA_FLAGS`.
3. It syncs the selected project files to `RCLONE_REMOTE/MIRROR_REMOTE_SUBDIR` under `MIRROR_ROOT_FOLDER_ID`.

### Slurm Supervision

1. `job_supervisor.sh` loads config.
2. If `SLURM_JOB_NAME` is unset or unknown, it falls back to `JOB_NOTIFICATION_NAME`.
3. Each loop iteration runs `relayctl.sh restart`.
4. If the restart fails, it logs the `relayctl` output and runs `repair_mount.sh`.
5. If `EMAIL_ON_START=1`, it launches `job_notifier.sh` once per supervisor run.
6. Near walltime, it stops the relay and performs cleanup.

## Mount Health Model

The command-channel mount is considered ready only if:

- the path is a mountpoint
- the mount responds to a `stat` call within a timeout

This avoids false positives where a daemonized `rclone mount` process briefly exists but the mount never becomes usable.

## Legacy Material

Older project-specific wrappers and historical notes are stored in `legacy/`.

They are not the preferred entrypoints for new use.
