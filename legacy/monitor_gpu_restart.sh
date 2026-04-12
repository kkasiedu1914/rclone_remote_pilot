#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Run from repo root (resolves symlinks).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$SCRIPT_DIR"

# ---- configurable knobs (override via env vars) ----
LOG_DIR="${LOG_DIR:-norm_pretrainlogs}"
DATASET_PATH="${DATASET_PATH:-tests/graph_data1}"
BATCH_SIZE="${BATCH_SIZE:-32}"
MEAN="${MEAN:-210.41926169323222}"
STD="${STD:-214.16638811009338}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
IDLE_CHECKS="${IDLE_CHECKS:-2}"
MIN_IDLE_MEM_MB="${MIN_IDLE_MEM_MB:-0}"
FORCE_RESTART_ON_IDLE="${FORCE_RESTART_ON_IDLE:-0}"
# Seed selection:
# - Set SEEDS (space- or comma-separated) to fully control which seeds run.
# - Otherwise, seeds are generated starting at SEED for NUM_INSTANCES.
SEED="${SEED:-4}"
NUM_INSTANCES="${NUM_INSTANCES:-1}"
SEEDS="${SEEDS:-}"
declare -A LOG_PREFIX=(
  [4]="pm_pretrain_seed4"
  [5]="mof_pretrain_seed5"
)

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "Error: nvidia-smi not found on PATH." >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
shopt -s nullglob

latest_ckpt() {
  local seed="$1"
  local matches=("$LOG_DIR/gscgcnn_transformer_seed${seed}_from_"/version_*/checkpoints/last.ckpt)
  if [[ ${#matches[@]} == 0 ]]; then
    echo ""
    return 0
  fi
  ls -t "${matches[@]}" | head -n1
}

gpu_mem_used_mb() {
  nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \
    | awk '{sum+=$1} END{print sum+0}'
}

is_running() {
  local seed="$1"
  local pidfile=".pid_seed${seed}"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  if pgrep -f "tests/run.py.*seed=${seed}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

stop_job() {
  local seed="$1"
  local pidfile=".pid_seed${seed}"
  if [[ -f "$pidfile" ]]; then
    local pid
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      sleep 2
      if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi
    rm -f "$pidfile"
  fi
}

start_job() {
  local seed="$1"
  local ckpt
  ckpt="$(latest_ckpt "$seed")"
  local resume_arg=()
  if [[ -n "$ckpt" ]]; then
    resume_arg=("resume_from=$ckpt")
  fi

  local prefix="${LOG_PREFIX[$seed]:-pretrain_seed${seed}}"
  local log_file="${LOG_DIR}/${prefix}_$(date +%Y%m%d_%H%M%S).log"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] starting seed ${seed} (ckpt: ${ckpt:-none})"
  python tests/run.py with \
    batch_size="$BATCH_SIZE" \
    dataset_path="$DATASET_PATH" \
    log_dir="${LOG_DIR}/" \
    mean="$MEAN" \
    std="$STD" \
    "${resume_arg[@]}" \
    knust_run \
    seed="$seed" \
    > "$log_file" 2>&1 &
  echo $! > ".pid_seed${seed}"
}

if [[ -n "$SEEDS" ]]; then
  IFS=$' ,\t\n' read -r -a SEEDS_ARR <<< "$SEEDS"
else
  SEEDS_ARR=()
  for ((i = 0; i < NUM_INSTANCES; i++)); do
    SEEDS_ARR+=($((SEED + i)))
  done
fi

idle_count=0
while true; do
  mem_used="$(gpu_mem_used_mb)"
  if [[ "$mem_used" -le "$MIN_IDLE_MEM_MB" ]]; then
    idle_count=$((idle_count + 1))
  else
    idle_count=0
  fi

  if [[ "$idle_count" -ge "$IDLE_CHECKS" ]]; then
    for seed in "${SEEDS_ARR[@]}"; do
      if is_running "$seed"; then
        if [[ "$FORCE_RESTART_ON_IDLE" == "1" ]]; then
          stop_job "$seed"
          start_job "$seed"
        fi
      else
        start_job "$seed"
      fi
    done
    idle_count=0
  fi

  sleep "$CHECK_INTERVAL"
done
