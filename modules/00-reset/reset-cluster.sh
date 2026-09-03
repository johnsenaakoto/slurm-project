#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
FORCE=false

usage() {
  echo "Usage: reset-cluster.sh [--config FILE] [--dry-run] [--force] [--help]"
  echo "Permanently delete only the configured Multipass cluster instances."
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
    --force)
      FORCE=true
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
init_observability "00-reset" "$LOG_DIR"

for variable in CONTROLLER_NAME WORKER1_NAME WORKER2_NAME LOG_DIR; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi
for node in "${nodes[@]}"; do
  [[ "$node" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    log ERROR "Configured instance name contains unsupported characters: $node"
    exit 1
  }
done

log INFO "Phase 1/3: resolve configured Multipass instances"
existing_nodes=()
for node in "${nodes[@]}"; do
  if multipass info "$node" >/dev/null 2>&1; then
    existing_nodes+=("$node")
    log INFO "Instance will be deleted: $node"
  else
    log INFO "Instance is already absent: $node"
  fi
done

if ((${#existing_nodes[@]} == 0)); then
  log INFO "Cluster is already reset; no configured instances exist"
  exit 0
fi

if [[ "$DRY_RUN" == true ]]; then
  log_command multipass delete --purge "${existing_nodes[@]}"
  log INFO "Dry run finished; no instances were deleted"
  exit 0
fi

if [[ "$FORCE" != true ]]; then
  [[ -r /dev/tty ]] || {
    log ERROR "Interactive confirmation is unavailable; rerun with --force"
    exit 1
  }
  printf 'This permanently deletes: %s\n' "${existing_nodes[*]}" >/dev/tty
  printf 'Type "delete slurm cluster" to continue: ' >/dev/tty
  IFS= read -r confirmation </dev/tty
  [[ "$confirmation" == "delete slurm cluster" ]] || {
    log ERROR "Confirmation did not match; nothing was deleted"
    exit 1
  }
fi

log INFO "Phase 2/3: permanently delete configured instances"
log_command multipass delete --purge "${existing_nodes[@]}"
multipass delete --purge "${existing_nodes[@]}"

log INFO "Phase 3/3: verify configured instances are absent"
for node in "${nodes[@]}"; do
  if multipass info "$node" >/dev/null 2>&1; then
    log ERROR "Instance still exists after reset: $node"
    exit 1
  fi
  log INFO "Absence verified: $node"
done

log INFO "Cluster reset completed; run Modules 01 through 05 to rebuild it"
