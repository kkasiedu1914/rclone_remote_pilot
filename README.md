# rclone_remote_pilot

`rclone_remote_pilot` is a general-purpose relay toolkit for running commands on one or more remote Linux or HPC projects through shared Google Drive command channels.

## What It Does

- mounts a shared Google Drive folder with `rclone mount`
- watches for an incoming `commands.sh`
- executes the command file locally when it changes
- auto-runs commands from the configured `PROJECT_DIR`
- republishes logs back into the shared command folder
- mirrors project outputs to a separate shared Drive folder
- optionally supervises the relay inside a Slurm job
- optionally sends start and finish email notifications for Slurm jobs

## Main Entry Points

- `configure.sh`: interactive setup for global defaults or named project instances
- `relayctl.sh`: start, stop, restart, or inspect the relay
- `relay.sh`: core relay loop
- `sync_mirror.sh`: mirror project outputs to the shared Drive mirror root
- `job_supervisor.sh`: Slurm/HPC watchdog
- `job_notifier.sh`: optional Slurm email notifier
- `repair_mount.sh`: mount cleanup helper

Compatibility wrappers are still present for the previous project-specific names:

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

Select the active project instance with:

```bash
export REMOTE_PILOT_PROJECT=my_project
```

Create or update that project instance with:

```bash
./configure.sh --project my_project
```

The default shared Google Drive access email is:

```text
compucatalysis@gmail.com
```

Default email behavior for ARC / VT-style setups:

- `SMTP_USER` defaults to `arc.knust.job.notifier@gmail.com`
- `NOTIFICATION_TO_SECONDARY` defaults to `achenie@vt.edu`
- `NOTIFICATION_TO_PRIMARY` has no default and should be set by the user

## Deployment Model

One shared code copy can manage multiple project instances on the same machine. Each project instance has its own:

- `PROJECT_DIR`
- `COMMAND_CHANNEL_FOLDER_ID`
- `MIRROR_ROOT_FOLDER_ID`
- mount point
- runtime state under `<PROJECT_DIR>/.remote-pilot/<project-name>/`

Commands execute from `PROJECT_DIR` automatically, so the pilot can live in a shared tools directory while the actual workload stays in its own project directory.

## Documentation

- [SETUP.md](./SETUP.md): full end-to-end setup guide
- [QUICK_SETUP.md](./QUICK_SETUP.md): shorter command summary

## Notes

- `send_email.py` is a minimal SMTP helper used by `job_notifier.sh`.
- `monitor_gpu_restart.sh` is not part of the core relay toolkit; it is retained as an extra operational example.
