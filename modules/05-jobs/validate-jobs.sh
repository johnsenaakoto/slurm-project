#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
REMOTE_OUTPUT=""
BATCH_HOST=""

usage() {
  cat <<'EOF'
Usage: validate-jobs.sh [--config FILE] [--dry-run] [--help]

Submit a two-node batch job, wait for successful completion, and verify its
output on the selected batch host without assuming shared storage.
EOF
}

while (($# > 0)); do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "Error: --config requires a file." >&2; exit 2; }
      CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v multipass >/dev/null 2>&1 || {
  echo "Error: Multipass is not installed or is not in PATH." >&2
  exit 1
}
[[ -r "$CONFIG_FILE" ]] || {
  echo "Error: cannot read configuration: $CONFIG_FILE" >&2
  exit 1
}

# shellcheck source=../../config/cluster.env
source "$CONFIG_FILE"
LOG_DIR="${LOG_DIR:-logs}"
[[ "$LOG_DIR" == /* ]] || LOG_DIR="${PROJECT_ROOT}/${LOG_DIR}"
# shellcheck source=../lib/observability.sh
source "${SCRIPT_DIR}/../lib/observability.sh"
init_observability "05-jobs" "$LOG_DIR"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME PARTITION_NAME
  JOB_TIMEOUT_SECONDS LOG_DIR
)
for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done
[[ "$PARTITION_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  log ERROR "PARTITION_NAME contains unsupported characters: $PARTITION_NAME"
  exit 1
}
[[ "$JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "JOB_TIMEOUT_SECONDS must be a positive integer"
  exit 1
}

module_cleanup() {
  local exit_code="$1"
  if [[ "$DRY_RUN" == false && -n "$REMOTE_OUTPUT" && -n "$BATCH_HOST" ]]; then
    multipass exec "$BATCH_HOST" -- rm -f -- "$REMOTE_OUTPUT" >/dev/null 2>&1 || true
  fi
  if ((exit_code != 0)); then
    log INFO "Failure cleanup completed"
  fi
  return 0
}

job_script="#!/bin/bash
#SBATCH --job-name=slurm-e2e
#SBATCH --partition=$PARTITION_NAME
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:01:00
#SBATCH --output=/tmp/slurm-e2e-%j.out

set -euo pipefail
echo \"JOB_START id=\$SLURM_JOB_ID nodes=\$SLURM_JOB_NODELIST\"
srun --label hostname
echo \"JOB_FINISH id=\$SLURM_JOB_ID\""

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Batch script that would be submitted follows"
  printf '%s\n' "$job_script"
  log INFO "Dry run finished; no job was submitted"
  exit 0
fi

log INFO "Phase 1/4: verify cluster readiness"
for node in "$WORKER1_NAME" "$WORKER2_NAME"; do
  state="$(multipass exec "$CONTROLLER_NAME" -- sinfo -h -N -n "$node" -o '%T')"
  [[ "$state" == idle ]] || {
    log ERROR "Worker is not idle: node=$node, state=${state:-<empty>}"
    exit 1
  }
done

log INFO "Phase 2/4: submit a two-node batch job"
submission="$(printf '%s\n' "$job_script" | multipass exec "$CONTROLLER_NAME" -- sbatch --parsable)"
job_id="${submission%%;*}"
[[ "$job_id" =~ ^[0-9]+$ ]] || {
  log ERROR "Could not parse the submitted job ID: $submission"
  exit 1
}
REMOTE_OUTPUT="/tmp/slurm-e2e-${job_id}.out"
log INFO "Submitted job $job_id"

log INFO "Phase 3/4: wait for successful completion"
deadline=$((SECONDS + JOB_TIMEOUT_SECONDS))
while true; do
  job_report="$(multipass exec "$CONTROLLER_NAME" -- scontrol show job -o "$job_id" 2>/dev/null || true)"
  state="$(sed -n 's/.*JobState=\([^ ]*\).*/\1/p' <<<"$job_report")"
  observed_batch_host="$(sed -n 's/.*BatchHost=\([^ ]*\).*/\1/p' <<<"$job_report")"
  case "$observed_batch_host" in
    "$WORKER1_NAME"|"$WORKER2_NAME") BATCH_HOST="$observed_batch_host" ;;
  esac
  case "$state" in
    COMPLETED)
      break
      ;;
    FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE)
      log ERROR "Job $job_id ended in state $state"
      log ERROR "Job report: $job_report"
      exit 1
      ;;
  esac
  if ((SECONDS >= deadline)); then
    multipass exec "$CONTROLLER_NAME" -- scancel "$job_id" >/dev/null 2>&1 || true
    log ERROR "Job $job_id did not complete within ${JOB_TIMEOUT_SECONDS}s (last state=${state:-unknown})"
    exit 1
  fi
  sleep 1
done

case "$BATCH_HOST" in
  "$WORKER1_NAME"|"$WORKER2_NAME") ;;
  *)
    log ERROR "Unexpected or missing BatchHost for job $job_id: ${BATCH_HOST:-<empty>}"
    exit 1
    ;;
esac
exit_code="$(sed -n 's/.*ExitCode=\([^ ]*\).*/\1/p' <<<"$job_report")"
[[ "$exit_code" == "0:0" ]] || {
  log ERROR "Job $job_id did not exit successfully: ExitCode=${exit_code:-<empty>}"
  exit 1
}

log INFO "Phase 4/4: retrieve and validate output from $BATCH_HOST"
output="$(multipass exec "$BATCH_HOST" -- cat "$REMOTE_OUTPUT")"
printf '%s\n' "$output"
grep -Fq "JOB_START id=$job_id" <<<"$output" || {
  log ERROR "Job output is missing its start marker"
  exit 1
}
grep -Fq "JOB_FINISH id=$job_id" <<<"$output" || {
  log ERROR "Job output is missing its finish marker"
  exit 1
}
for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  grep -Fq "$worker" <<<"$output" || {
    log ERROR "Job output does not contain task execution on $worker"
    exit 1
  }
done
task_count="$(grep -Ec '^[0-9]+: .+$' <<<"$output")"
[[ "$task_count" == 2 ]] || {
  log ERROR "Expected two labeled task lines; observed $task_count"
  exit 1
}

log INFO "Job $job_id completed successfully across both workers; output was stored on $BATCH_HOST"
