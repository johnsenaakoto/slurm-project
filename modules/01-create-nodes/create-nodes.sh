#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: create-nodes.sh [--config FILE] [--dry-run] [--help]

Create the Multipass instances defined in the configuration file.
Existing instances are skipped and never modified or deleted.
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
init_observability "01-create-nodes" "$LOG_DIR"

required_variables=(
  UBUNTU_IMAGE
  CONTROLLER_NAME CONTROLLER_CPUS CONTROLLER_MEMORY CONTROLLER_DISK
  WORKER1_NAME WORKER1_CPUS WORKER1_MEMORY WORKER1_DISK
  WORKER2_NAME WORKER2_CPUS WORKER2_MEMORY WORKER2_DISK
  LOG_DIR
)

for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done

if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi

create_node() {
  local name="$1"
  local cpus="$2"
  local memory="$3"
  local disk="$4"
  local command=(
    multipass launch "$UBUNTU_IMAGE"
    --name "$name"
    --cpus "$cpus"
    --memory "$memory"
    --disk "$disk"
  )

  if multipass info "$name" >/dev/null 2>&1; then
    log INFO "Instance already exists; leaving unchanged: $name"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    log INFO "Instance is absent; launch would be required: $name"
    log_command "${command[@]}"
    return
  fi

  log INFO "Creating instance: $name (cpus=$cpus, memory=$memory, disk=$disk, image=$UBUNTU_IMAGE)"
  log_command "${command[@]}"
  "${command[@]}"
  log INFO "Multipass reported a successful launch: $name"
}

log INFO "Phase 1/2: create missing instances"
create_node "$CONTROLLER_NAME" "$CONTROLLER_CPUS" "$CONTROLLER_MEMORY" "$CONTROLLER_DISK"
create_node "$WORKER1_NAME" "$WORKER1_CPUS" "$WORKER1_MEMORY" "$WORKER1_DISK"
create_node "$WORKER2_NAME" "$WORKER2_CPUS" "$WORKER2_MEMORY" "$WORKER2_DISK"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry run finished; no instances were created"
  exit 0
fi

log INFO "Current Multipass inventory follows"
multipass list

log INFO "Phase 2/2: verify instance state, hostname, and operating system"
verification_failures=0
for node in "$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME"; do
  state="$(multipass info "$node" --format csv | tail -n 1 | cut -d, -f2)"
  if [[ "$state" != "Running" ]]; then
    log ERROR "$node is not running (state=$state); guest verification cannot continue"
    verification_failures=$((verification_failures + 1))
    continue
  fi

  guest_summary="$(multipass exec "$node" -- sh -c \
    '. /etc/os-release; printf "hostname=%s, os=%s, version=%s, architecture=%s" "$(hostname)" "$ID" "$VERSION_ID" "$(uname -m)"')"
  log INFO "$node verified: state=$state, $guest_summary"
done

if ((verification_failures > 0)); then
  log ERROR "$verification_failures node(s) failed verification"
  exit 1
fi

log INFO "All three nodes passed verification"
