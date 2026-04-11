  How To Use It Now

  1. User creates the project locally

  On the user machine, in the project repo:

  cd /path/to/project-repo
  git clone <pilot-repo-or-copy-it> rclone_remote_pilot
  cd rclone_remote_pilot

  Or if the pilot is already inside the repo, just go to it.

  2. User creates the Drive folders

  In Google Drive:

  1. Create command-channel
  2. Create mirror-root
  3. Share both with:
     compucatalysis@gmail.com
  4. Copy both folder IDs

  3. User runs config locally

  The user should enter the HPC paths, not their laptop paths.

  Example:

  cd /path/to/project-repo/rclone_remote_pilot
  ./configure.sh --project project_a

  When prompted, the user should enter things like:

  - PROJECT_DIR
    /scratch/alice/project_a
  - COMMAND_CHANNEL_FOLDER_ID
    <Drive folder ID>
  - MIRROR_ROOT_FOLDER_ID
    <Drive folder ID>
  - COMMAND_CHANNEL_MOUNT
    /home/alice/remote-pilot/project_a/command-channel
  - MIRROR_REMOTE_SUBDIR
    project_a/node1
  - SMTP_USER
    leave default
  - NOTIFICATION_TO_PRIMARY
    set this to the real user email
  - NOTIFICATION_TO_SECONDARY
    leave default if desired
  - NOTIFIER_PASSWORD_FILE
    leave default unless needed

  That writes:

  projects/project_a.env

  4. User commits and pushes

  Because projects/project_a.env is now commitable:

  git add rclone_remote_pilot/projects/project_a.env
  git add rclone_remote_pilot/.gitignore
  git add rclone_remote_pilot/configure.sh
  git add rclone_remote_pilot/lib/config.sh
  git add rclone_remote_pilot/README.md
  git add rclone_remote_pilot/SETUP.md
  git add rclone_remote_pilot/QUICK_SETUP.md
  git commit -m "Configure remote pilot for project_a"
  git push

  The secret itself is still not stored in git. Only the password-file path is stored.

  5. HPC pulls the repo

  On HPC:

  cd /scratch/alice/project_a
  git pull
  cd rclone_remote_pilot

  Now the HPC has the committed config file:
  projects/project_a.env

  6. HPC sets the password file once

  On HPC:

  mkdir -p ~/.secrets
  chmod 700 ~/.secrets
  printf '%s\n' 'your-app-password' > ~/.secrets/remote_pilot_gmail_app_password
  chmod 600 ~/.secrets/remote_pilot_gmail_app_password

  That satisfies the default NOTIFIER_PASSWORD_FILE.

  7. HPC selects the project instance

  export REMOTE_PILOT_PROJECT=project_a

  This is the one required “which project am I running?” step.

  8. Plain relay test

  Start the relay:

  ./relayctl.sh start
  ./relayctl.sh status

  Then the user places this in the shared command-channel/commands.sh:

  #!/usr/bin/env bash
  set -euo pipefail

  echo "test ok"
  hostname
  pwd
  date -Is

  Expected:

  - pwd should be /scratch/alice/project_a
  - logs appear under:
    /scratch/alice/project_a/.remote-pilot/project_a/logs/
  - logs also appear in Drive under:
    command-channel/logs/

  9. Mirror test

  On HPC:

  ./sync_mirror.sh

  This mirrors PROJECT_DIR by default.

  10. Slurm monitored run with email

  Inside a Slurm job on HPC:

  export REMOTE_PILOT_PROJECT=project_a
  ./job_supervisor.sh

  What happens:

  - it restarts the relay
  - it launches job_notifier.sh once
  - STARTED email is sent
  - FINISHED email is sent when the job ends
  - relay logs continue to publish during the job

  Day-to-Day Simple Flow

  Once the repo is configured and pulled on HPC, the operational flow is:

  export REMOTE_PILOT_PROJECT=project_a
  ./relayctl.sh start

  For a Slurm-managed monitored run:

  export REMOTE_PILOT_PROJECT=project_a
  ./job_supervisor.sh

  Useful commands:

  export REMOTE_PILOT_PROJECT=project_a
  ./relayctl.sh status
  ./relayctl.sh restart
  ./relayctl.sh stop
  ./sync_mirror.sh
  ./job_supervisor.sh

  Mental Model

  The workflow is now the one you described:

  1. User owns the setup experience.
  2. User runs config locally.
  3. User enters HPC paths and recipient email.
  4. Config file is saved in the repo.
  5. Config file is committed and pushed.
  6. HPC pulls repo.
  7. HPC only needs:
      - the project name export
      - the app-password file present
      - ./job_supervisor.sh or ./relayctl.sh

