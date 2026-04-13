# Operations

## Startup

Select a project:

```bash
export REMOTE_PILOT_PROJECT=demo_project
```

Start the relay:

```bash
bash rclone_remote_pilot/relayctl.sh start
```

Check status:

```bash
bash rclone_remote_pilot/relayctl.sh status
```

Stop:

```bash
bash rclone_remote_pilot/relayctl.sh stop
```

## Supervisor

Launch the supervisor:

```bash
export REMOTE_PILOT_PROJECT=demo_project
bash rclone_remote_pilot/job_supervisor.sh
```

Stop it:

```bash
pkill -f 'job_supervisor.sh' || true
pkill -f 'job_notifier.sh' || true
export REMOTE_PILOT_PROJECT=demo_project
bash rclone_remote_pilot/relayctl.sh stop || true
```

## Mount Repair

Force-reset a stale mount path:

```bash
export REMOTE_PILOT_PROJECT=demo_project
bash rclone_remote_pilot/repair_mount.sh
```

Recommended recovery sequence after repeated mount failures:

```bash
export REMOTE_PILOT_PROJECT=demo_project
pkill -f 'job_supervisor.sh' || true
pkill -f 'job_notifier.sh' || true
pkill -f 'relay.sh' || true
bash rclone_remote_pilot/relayctl.sh stop || true
bash rclone_remote_pilot/repair_mount.sh || true
bash rclone_remote_pilot/relayctl.sh start
```

## Command File

The relay watches:

```text
$COMMAND_CHANNEL_MOUNT/$COMMAND_FILE_NAME
```

The relay auto-creates that file if it is missing.

Example:

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "remote pilot test"
hostname
pwd
date -Is
```

## Custom Logs In `commands.sh`

The relay always writes to `COMMAND_OUTPUT_LOG_FILE`. Your command file can also write:

- a small custom summary log such as `cmd.log`
- one or more dedicated logs for separate background processes

Example:

```bash
#!/usr/bin/env bash
set -u
set +e
set -o pipefail

echo "Status: launching worker $(date -Is)" >> cmd.log 2>&1
nohup python src/train.py configs/demo_config.json >> outputs/train_worker.log 2>&1 &
echo "Status: worker started" >> cmd.log 2>&1
cp -f cmd.log "$COMMAND_CHANNEL_MOUNT/logs/" 2>/dev/null || true
```

## Exit Codes In Command Logs

The `command-output.log` file records relay-run summaries such as:

```text
=== RUN END ... status=OK exit_code=0 ===
=== RUN END ... status=FAILED exit_code=2 ===
=== RUN END ... status=TIMEOUT exit_code=124 ===
```

These `exit_code=` values are the exit codes returned by the executed command or shell script, not by `relayctl.sh`.

Common meanings:

- `0`
  Success.
- `124`
  Timeout from the `timeout` utility. This means the command exceeded `COMMAND_TIMEOUT_SECS`.
- `1`
  Generic failure from the command or shell script.
- `2`
  Common shell / CLI usage error. Often indicates bad arguments, a missing file path, or a script misuse.
- other non-zero codes
  Passed through from the executed command.

Important relay behavior:

- a non-zero command exit is logged as `status=FAILED`
- a timeout is logged as `status=TIMEOUT`
- if `TIMEOUT_REQUEUE_TO_BG=1`, a timed-out foreground run is relaunched in background mode
- the relay process itself does not crash just because the command returned a non-zero exit code

## Notification Emails

The notifier sends:

- STARTED
- FINISHED with final Slurm state

Default tailed files in the email body:

- `slurm-${SLURM_JOB_ID}.out`
- `RELAY_LOG_FILE`
- `SUPERVISOR_LOG_FILE`

If `SLURM_JOB_NAME` is unset or unknown, the notifier falls back to `PROJECT_NAME`.

## Mirroring

Run a normal mirror:

```bash
export REMOTE_PILOT_PROJECT=demo_project
bash rclone_remote_pilot/sync_mirror.sh
```

Override filters for one run:

```bash
export REMOTE_PILOT_PROJECT=demo_project
export SYNC_INCLUDE_GLOBS="outputs/** checkpoints/** reports/** *.csv *.txt"
export SYNC_EXCLUDES=".git/** .remote-pilot/** checkpoints/tmp/** *.tmp"
export RCLONE_EXTRA_FLAGS="--fast-list --transfers=16 --checkers=16"
bash rclone_remote_pilot/sync_mirror.sh
```

## File Transfer Patterns

Use the mounted command folder for:

- `commands.sh`
- small helper files
- small config files
- lightweight control artifacts

Use `sync_mirror.sh` for:

- routine outputs
- reports
- checkpoints you want mirrored with the rest of the project outputs

Use a separate storage backend for large transfers:

```bash
rclone copy outputs/checkpoint.pt gcs:my-remote-pilot-bucket/demo_project/
```

or:

```bash
gsutil cp outputs/checkpoint.pt gs://my-remote-pilot-bucket/demo_project/
```

The pilot does not configure GCS automatically. Configure that separately on the remote machine if you want to use it.
