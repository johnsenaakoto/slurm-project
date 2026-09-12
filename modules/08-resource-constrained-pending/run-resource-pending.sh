#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
BLOCKER_JOB_ID=""
WAITER_JOB_ID=""

usage() {
  cat <<'EOF'
Usage: run-resource-pending.sh [--config FILE] [--dry-run] [--help]

Fill the two-worker Slurm cluster, submit a waiter job, observe that it remains
pending for lack of available resources, then release capacity and verify the
waiter completes.
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
init_observability "08-resource-constrained-pending" "$LOG_DIR"

RESOURCE_PENDING_TIMEOUT_SECONDS="${RESOURCE_PENDING_TIMEOUT_SECONDS:-180}"
RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS="${RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS:-180}"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME PARTITION_NAME
  RESOURCE_PENDING_TIMEOUT_SECONDS RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS LOG_DIR
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
[[ "$RESOURCE_PENDING_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "RESOURCE_PENDING_TIMEOUT_SECONDS must be a positive integer"
  exit 1
}
[[ "$RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS must be a positive integer"
  exit 1
}

workers=("$WORKER1_NAME" "$WORKER2_NAME")
BLOCKER_TASKS_PER_NODE="${RESOURCE_PENDING_BLOCKER_TASKS_PER_NODE:-}"

module_cleanup() {
  local exit_code="$1"

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  if [[ -n "$WAITER_JOB_ID" ]]; then
    multipass exec "$CONTROLLER_NAME" -- scancel "$WAITER_JOB_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$BLOCKER_JOB_ID" ]]; then
    multipass exec "$CONTROLLER_NAME" -- scancel "$BLOCKER_JOB_ID" >/dev/null 2>&1 || true
  fi
  if ((exit_code != 0)); then
    log INFO "Cancelled submitted jobs from failed run: blocker=${BLOCKER_JOB_ID:-none}, waiter=${WAITER_JOB_ID:-none}"
  fi
}

job_report() {
  local job_id="$1"
  multipass exec "$CONTROLLER_NAME" -- scontrol show job -o "$job_id" 2>/dev/null || true
}

job_field() {
  local field="$1"
  local report="$2"
  sed -n "s/.*${field}=\\([^ ]*\\).*/\\1/p" <<<"$report"
}

queue_snapshot() {
  multipass exec "$CONTROLLER_NAME" -- squeue -o "%.18i %.18j %.8T %.12M %.20R %.19S" || true
}

submit_inline_job() {
  local script="$1"
  local submission

  submission="$(printf '%s\n' "$script" | multipass exec "$CONTROLLER_NAME" -- sbatch --parsable)"
  submission="${submission%%;*}"
  [[ "$submission" =~ ^[0-9]+$ ]] || {
    log ERROR "Could not parse submitted job ID: $submission"
    exit 1
  }
  printf '%s\n' "$submission"
}

wait_for_state() {
  local job_id="$1"
  local wanted_state="$2"
  local deadline=$((SECONDS + RESOURCE_PENDING_TIMEOUT_SECONDS))
  local report state

  while true; do
    report="$(job_report "$job_id")"
    state="$(job_field JobState "$report")"
    if [[ "$state" == "$wanted_state" ]]; then
      return 0
    fi
    case "$state" in
      FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|SPECIAL_EXIT)
        log ERROR "Job $job_id ended in state $state while waiting for $wanted_state"
        log ERROR "Job report: $report"
        exit 1
        ;;
    esac
    if ((SECONDS >= deadline)); then
      log ERROR "Job $job_id did not reach $wanted_state within ${RESOURCE_PENDING_TIMEOUT_SECONDS}s"
      queue_snapshot
      log ERROR "Job report: $report"
      exit 1
    fi
    sleep 1
  done
}

if [[ "$DRY_RUN" == true ]]; then
  BLOCKER_TASKS_PER_NODE="${BLOCKER_TASKS_PER_NODE:-2}"
else
  log INFO "Phase 1/6: verify both workers are idle and discover worker CPUs"
  for worker in "${workers[@]}"; do
    state="$(multipass exec "$CONTROLLER_NAME" -- sinfo -h -N -n "$worker" -o '%T')"
    [[ "$state" == idle ]] || {
      log ERROR "Worker must be idle before this lab: node=$worker, state=${state:-<empty>}"
      log ERROR "Cancel or wait for existing jobs, then rerun the module."
      exit 1
    }
    cpu_count="$(multipass exec "$CONTROLLER_NAME" -- sinfo -h -N -n "$worker" -o '%c')"
    [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || {
      log ERROR "Could not determine configured CPU count for $worker: ${cpu_count:-<empty>}"
      exit 1
    }
    if [[ -z "$BLOCKER_TASKS_PER_NODE" ]]; then
      BLOCKER_TASKS_PER_NODE="$cpu_count"
    elif [[ "$BLOCKER_TASKS_PER_NODE" != "$cpu_count" ]]; then
      log ERROR "Workers have different CPU counts or override is inconsistent: expected $BLOCKER_TASKS_PER_NODE, observed $cpu_count on $worker"
      exit 1
    fi
  done
fi
[[ "$BLOCKER_TASKS_PER_NODE" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "RESOURCE_PENDING_BLOCKER_TASKS_PER_NODE must be a positive integer when set"
  exit 1
}
log INFO "Blocker will request $BLOCKER_TASKS_PER_NODE task(s) per worker node"

blocker_job_script="#!/bin/bash
#SBATCH --job-name=resource-blocker
#SBATCH --partition=$PARTITION_NAME
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=$BLOCKER_TASKS_PER_NODE
#SBATCH --time=00:05:00
#SBATCH --output=/tmp/resource-blocker-%j.out

set -euo pipefail
echo \"BLOCKER_START job=\$SLURM_JOB_ID nodes=\$SLURM_JOB_NODELIST\"
srun --label bash -c 'echo \"running on \$(hostname)\"; sleep $RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS'
echo \"BLOCKER_DONE job=\$SLURM_JOB_ID\""

waiter_job_script="#!/bin/bash
#SBATCH --job-name=resource-waiter
#SBATCH --partition=$PARTITION_NAME
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --time=00:01:00
#SBATCH --output=/tmp/resource-waiter-%j.out

set -euo pipefail
echo \"WAITER_START job=\$SLURM_JOB_ID node=\$(hostname)\"
sleep 5
echo \"WAITER_DONE job=\$SLURM_JOB_ID\""

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Blocker job script that would be submitted follows"
  printf '%s\n' "$blocker_job_script"
  log INFO "Waiter job script that would be submitted follows"
  printf '%s\n' "$waiter_job_script"
  log INFO "Dry run finished; no jobs were submitted"
  exit 0
fi

log INFO "Phase 2/6: submit a blocker job that fills both workers"
BLOCKER_JOB_ID="$(submit_inline_job "$blocker_job_script")"
log INFO "Submitted blocker job $BLOCKER_JOB_ID"
wait_for_state "$BLOCKER_JOB_ID" RUNNING
log INFO "Blocker job is running; current queue:"
queue_snapshot

log INFO "Phase 3/6: submit a waiter job that needs one worker CPU"
WAITER_JOB_ID="$(submit_inline_job "$waiter_job_script")"
log INFO "Submitted waiter job $WAITER_JOB_ID"

log INFO "Phase 4/6: observe waiter pending while blocker holds the worker CPUs"
deadline=$((SECONDS + RESOURCE_PENDING_TIMEOUT_SECONDS))
while true; do
  waiter_report="$(job_report "$WAITER_JOB_ID")"
  waiter_state="$(job_field JobState "$waiter_report")"
  waiter_reason="$(job_field Reason "$waiter_report")"
  waiter_alloc_tres="$(job_field AllocTRES "$waiter_report")"
  waiter_sched_node="$(job_field SchedNodeList "$waiter_report")"
  blocker_state="$(job_field JobState "$(job_report "$BLOCKER_JOB_ID")")"

  if [[ "$waiter_state" == PENDING && "$blocker_state" == RUNNING ]]; then
    case "$waiter_reason" in
      Resources)
        log INFO "Observed expected pending state: job=$WAITER_JOB_ID reason=Resources"
        break
        ;;
      None)
        if [[ "$waiter_alloc_tres" == "(null)" ]]; then
          log INFO "Observed expected pending state: job=$WAITER_JOB_ID reason=None alloc_tres=$waiter_alloc_tres scheduled_node=${waiter_sched_node:-unknown}"
          log INFO "Slurm is showing None, but the waiter is pending with no allocation while the blocker owns the worker CPUs."
          break
        fi
        ;;
      InvalidAccount)
        log INFO "Waiter temporarily reports InvalidAccount; continuing until Slurm settles the schedulable pending reason"
        ;;
    esac
  fi
  case "$waiter_state" in
    FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|SPECIAL_EXIT)
      log ERROR "Waiter job $WAITER_JOB_ID ended in state $waiter_state before the pending resource condition was observed"
      log ERROR "Job report: $waiter_report"
      exit 1
      ;;
    RUNNING|COMPLETED)
      log ERROR "Waiter job $WAITER_JOB_ID started before the resource-constrained pending condition was observed"
      log ERROR "This usually means the blocker did not consume all configured worker CPUs."
      queue_snapshot
      log ERROR "Waiter report: $waiter_report"
      exit 1
      ;;
  esac
  if ((SECONDS >= deadline)); then
    log ERROR "Waiter job $WAITER_JOB_ID did not reach the expected pending condition within ${RESOURCE_PENDING_TIMEOUT_SECONDS}s"
    queue_snapshot
    log ERROR "Last waiter report: $waiter_report"
    exit 1
  fi
  sleep 2
done
queue_snapshot

log INFO "Phase 5/6: cancel the blocker to release cluster capacity"
multipass exec "$CONTROLLER_NAME" -- scancel "$BLOCKER_JOB_ID" >/dev/null 2>&1 || true
BLOCKER_JOB_ID=""

log INFO "Phase 6/6: verify the formerly pending waiter runs and completes"
wait_for_state "$WAITER_JOB_ID" COMPLETED
final_report="$(job_report "$WAITER_JOB_ID")"
exit_code="$(job_field ExitCode "$final_report")"
[[ "$exit_code" == "0:0" ]] || {
  log ERROR "Waiter job $WAITER_JOB_ID did not exit successfully: ExitCode=${exit_code:-<empty>}"
  log ERROR "Job report: $final_report"
  exit 1
}
WAITER_JOB_ID=""

log INFO "Resource-constrained pending lab completed successfully"
