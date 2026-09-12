#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
CHANGED_WORKER1=false
CHANGED_WORKER2=false

usage() {
  cat <<'EOF'
Usage: run-node-drain-recovery.sh [--config FILE] [--dry-run] [--help]

Drain one Slurm worker, mark another worker down, then recover both nodes and
verify that the partition returns to an idle state.
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
init_observability "09-node-drain-recovery" "$LOG_DIR"

NODE_RECOVERY_TIMEOUT_SECONDS="${NODE_RECOVERY_TIMEOUT_SECONDS:-60}"
NODE_DRAIN_REASON="${NODE_DRAIN_REASON:-lesson-drain}"
NODE_FAILURE_REASON="${NODE_FAILURE_REASON:-lesson-failure}"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME PARTITION_NAME
  NODE_RECOVERY_TIMEOUT_SECONDS NODE_DRAIN_REASON NODE_FAILURE_REASON LOG_DIR
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
[[ "$NODE_RECOVERY_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "NODE_RECOVERY_TIMEOUT_SECONDS must be a positive integer"
  exit 1
}
for reason in "$NODE_DRAIN_REASON" "$NODE_FAILURE_REASON"; do
  [[ "$reason" =~ ^[a-zA-Z0-9._=-]+$ ]] || {
    log ERROR "Reasons must avoid spaces and shell metacharacters: $reason"
    exit 1
  }
done
if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi

node_state() {
  local node="$1"
  multipass exec "$CONTROLLER_NAME" -- sinfo -h -N -n "$node" -o '%T'
}

show_nodes() {
  multipass exec "$CONTROLLER_NAME" -- sinfo -Nel
}

wait_for_state() {
  local node="$1"
  local expected="$2"
  local deadline=$((SECONDS + NODE_RECOVERY_TIMEOUT_SECONDS))
  local state=""

  while true; do
    state="$(node_state "$node")"
    if [[ "$state" == "$expected" ]]; then
      log INFO "$node reached state $expected"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      log ERROR "$node did not reach state $expected within ${NODE_RECOVERY_TIMEOUT_SECONDS}s; last state=${state:-<empty>}"
      return 1
    fi
    sleep 1
  done
}

clear_reason() {
  local node="$1"
  multipass exec "$CONTROLLER_NAME" -- sudo scontrol update "NodeName=$node" Reason=none >/dev/null
}

recover_node() {
  local node="$1"
  local state

  state="$(node_state "$node")"
  if [[ "$state" != idle ]]; then
    multipass exec "$CONTROLLER_NAME" -- sudo scontrol update "NodeName=$node" State=RESUME >/dev/null 2>&1 ||
      multipass exec "$CONTROLLER_NAME" -- sudo scontrol update "NodeName=$node" State=IDLE >/dev/null
    wait_for_state "$node" idle
  else
    log INFO "$node is already idle; clearing stale reason only"
  fi
  clear_reason "$node"
}

module_cleanup() {
  local exit_code="$1"

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  if [[ "$CHANGED_WORKER1" == true || "$CHANGED_WORKER2" == true ]]; then
    log INFO "Cleanup: recover nodes touched by this module"
  fi
  if [[ "$CHANGED_WORKER1" == true ]]; then
    recover_node "$WORKER1_NAME" || true
  fi
  if [[ "$CHANGED_WORKER2" == true ]]; then
    recover_node "$WORKER2_NAME" || true
  fi
  if ((exit_code != 0)); then
    show_nodes || true
  fi
}

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry run plan follows"
  log INFO "Would verify $WORKER1_NAME and $WORKER2_NAME are idle in partition $PARTITION_NAME"
  log INFO "Would demonstrate non-admin failure: scontrol update NodeName=$WORKER1_NAME State=DRAIN Reason=$NODE_DRAIN_REASON"
  log INFO "Would drain: sudo scontrol update NodeName=$WORKER1_NAME State=DRAIN Reason=$NODE_DRAIN_REASON"
  log INFO "Would mark down: sudo scontrol update NodeName=$WORKER2_NAME State=DOWN Reason=$NODE_FAILURE_REASON"
  log INFO "Would verify controller health with scontrol ping"
  log INFO "Would recover both workers and clear stale reasons"
  log INFO "Dry run finished; no Slurm node state was changed"
  exit 0
fi

log INFO "Phase 1/7: verify controller and idle workers"
multipass exec "$CONTROLLER_NAME" -- scontrol ping
for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  state="$(node_state "$worker")"
  [[ "$state" == idle ]] || {
    log ERROR "Expected $worker to start idle; observed state=${state:-<empty>}"
    exit 1
  }
done
show_nodes

log INFO "Phase 2/7: demonstrate that normal users cannot change node state"
non_admin_output="$(
  multipass exec "$CONTROLLER_NAME" -- scontrol update "NodeName=$WORKER1_NAME" State=DRAIN "Reason=$NODE_DRAIN_REASON" 2>&1 || true
)"
printf '%s\n' "$non_admin_output"
grep -Fq "Invalid user id" <<<"$non_admin_output" || {
  log ERROR "Expected non-admin scontrol update to fail with Invalid user id"
  exit 1
}

log INFO "Phase 3/7: drain $WORKER1_NAME"
multipass exec "$CONTROLLER_NAME" -- sudo scontrol update "NodeName=$WORKER1_NAME" State=DRAIN "Reason=$NODE_DRAIN_REASON"
CHANGED_WORKER1=true
wait_for_state "$WORKER1_NAME" drained
show_nodes

log INFO "Phase 4/7: mark $WORKER2_NAME down"
multipass exec "$CONTROLLER_NAME" -- sudo scontrol update "NodeName=$WORKER2_NAME" State=DOWN "Reason=$NODE_FAILURE_REASON"
CHANGED_WORKER2=true
wait_for_state "$WORKER2_NAME" down
show_nodes

log INFO "Phase 5/7: confirm slurmctld is still healthy"
multipass exec "$CONTROLLER_NAME" -- scontrol ping
log INFO "The controller is up even though no worker is currently allocatable"

log INFO "Phase 6/7: recover both workers"
recover_node "$WORKER1_NAME"
recover_node "$WORKER2_NAME"
CHANGED_WORKER1=false
CHANGED_WORKER2=false

log INFO "Phase 7/7: verify both workers are idle with cleared reasons"
wait_for_state "$WORKER1_NAME" idle
wait_for_state "$WORKER2_NAME" idle
show_nodes
log INFO "Node drain, failure, recovery, and resume exercise completed"
