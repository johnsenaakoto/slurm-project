#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: install-and-validate.sh [--config FILE] [--dry-run] [--help]

Install role-specific Slurm packages, distribute the controller's MUNGE key,
and validate local and cross-node authentication.
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
init_observability "03-software-and-munge" "$LOG_DIR"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME
  CONTROLLER_PACKAGES WORKER_PACKAGES APT_UPDATE LOG_DIR
)
for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done

[[ "$APT_UPDATE" == "true" || "$APT_UPDATE" == "false" ]] || {
  log ERROR "APT_UPDATE must be true or false; observed: $APT_UPDATE"
  exit 1
}

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
MUNGE_MAINTENANCE=false
KEY_STAGING_STARTED=false
if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi

module_cleanup() {
  local exit_code="$1"
  local cleanup_failed=false

  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi

  # There should never be a staged key after a successful atomic move. Remove
  # this exact known path on workers after either success or failure.
  if [[ "$KEY_STAGING_STARTED" == true ]]; then
    for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
      multipass exec "$worker" -- sudo rm -f /etc/munge/munge.key.new >/dev/null 2>&1 || cleanup_failed=true
    done
  fi

  if [[ "$MUNGE_MAINTENANCE" == true ]]; then
    log WARNING "Run ended during MUNGE key maintenance; attempting service recovery"
    for node in "${nodes[@]}"; do
      if multipass exec "$node" -- sudo systemctl start munge >/dev/null 2>&1; then
        log INFO "Recovery started MUNGE: $node"
      else
        log ERROR "Recovery could not start MUNGE: $node"
        cleanup_failed=true
      fi
    done
  fi

  if [[ "$cleanup_failed" == true ]]; then
    return 1
  fi
  if ((exit_code != 0)); then
    log INFO "Failure cleanup completed"
  fi
}

read -r -a controller_packages <<<"$CONTROLLER_PACKAGES"
read -r -a worker_packages <<<"$WORKER_PACKAGES"
for package in "${controller_packages[@]}" "${worker_packages[@]}"; do
  [[ "$package" =~ ^[a-zA-Z0-9.+-]+$ ]] || {
    log ERROR "Invalid package name in configuration: $package"
    exit 1
  }
done

log INFO "Phase 1/7: verify Multipass instances"
for node in "${nodes[@]}"; do
  if ! multipass info "$node" >/dev/null 2>&1; then
    log ERROR "Multipass instance does not exist or is unavailable: $node"
    exit 1
  fi
  log INFO "Instance is available: $node"
done

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Planned controller packages: $CONTROLLER_PACKAGES"
  log INFO "Planned worker packages: $WORKER_PACKAGES"
  if [[ "$APT_UPDATE" == true ]]; then
    for node in "${nodes[@]}"; do
      log_command multipass exec "$node" -- sudo apt-get update
    done
  fi
  log_command multipass exec "$CONTROLLER_NAME" -- sudo apt-get install -y "${controller_packages[@]}"
  log_command multipass exec "$WORKER1_NAME" -- sudo apt-get install -y "${worker_packages[@]}"
  log_command multipass exec "$WORKER2_NAME" -- sudo apt-get install -y "${worker_packages[@]}"
  log INFO "MUNGE key synchronization and validation would follow installation"
  log INFO "Dry run finished; no packages, keys, or services were changed"
  exit 0
fi

log INFO "Phase 2/7: refresh package indexes"
if [[ "$APT_UPDATE" == true ]]; then
  for node in "${nodes[@]}"; do
    log INFO "Refreshing APT indexes: $node"
    multipass exec "$node" -- sudo apt-get update
  done
else
  log INFO "APT index refresh disabled by configuration"
fi

log INFO "Phase 3/7: install role-specific software"
log INFO "Installing controller packages on $CONTROLLER_NAME: $CONTROLLER_PACKAGES"
multipass exec "$CONTROLLER_NAME" -- sudo env DEBIAN_FRONTEND=noninteractive \
  apt-get install -y "${controller_packages[@]}"
for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  log INFO "Installing worker packages on $worker: $WORKER_PACKAGES"
  multipass exec "$worker" -- sudo env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y "${worker_packages[@]}"
done

log INFO "Slurm daemon lifecycle is deferred to Module 04"

log INFO "Phase 4/7: synchronize the controller MUNGE key"
MUNGE_MAINTENANCE=true
KEY_STAGING_STARTED=true
for node in "${nodes[@]}"; do
  log INFO "Stopping MUNGE before key maintenance: $node"
  multipass exec "$node" -- sudo systemctl stop munge
done

if ! multipass exec "$CONTROLLER_NAME" -- sudo test -s /etc/munge/munge.key; then
  log ERROR "Controller MUNGE key is missing or empty: /etc/munge/munge.key"
  exit 1
fi

log INFO "Normalizing controller key ownership and permissions"
multipass exec "$CONTROLLER_NAME" -- sudo chown munge:munge /etc/munge/munge.key
multipass exec "$CONTROLLER_NAME" -- sudo chmod 0400 /etc/munge/munge.key

for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  log INFO "Streaming authoritative key from $CONTROLLER_NAME to $worker"
  multipass exec "$CONTROLLER_NAME" -- sudo base64 /etc/munge/munge.key |
    multipass exec "$worker" -- sudo sh -c \
      'umask 077; base64 -d > /etc/munge/munge.key.new; chown munge:munge /etc/munge/munge.key.new; chmod 0400 /etc/munge/munge.key.new; mv /etc/munge/munge.key.new /etc/munge/munge.key'
done

log INFO "Phase 5/7: enable and start MUNGE"
for node in "${nodes[@]}"; do
  log INFO "Enabling and starting MUNGE: $node"
  multipass exec "$node" -- sudo systemctl enable --now munge
done
MUNGE_MAINTENANCE=false

log INFO "Phase 6/7: verify packages, versions, keys, and services"
slurm_client_version=""
controller_fingerprint=""
for index in "${!nodes[@]}"; do
  node="${nodes[$index]}"
  if ((index == 0)); then
    expected_packages=("${controller_packages[@]}")
    daemon_version="$(multipass exec "$node" -- slurmctld -V)"
  else
    expected_packages=("${worker_packages[@]}")
    daemon_version="$(multipass exec "$node" -- slurmd -V)"
  fi

  for package in "${expected_packages[@]}"; do
    package_status="$(multipass exec "$node" -- dpkg-query -W -f='${db:Status-Abbrev} ${Version}' "$package")"
    [[ "$package_status" == ii\ * ]] || {
      log ERROR "Package verification failed: node=$node, package=$package, observed='$package_status'"
      exit 1
    }
    log INFO "Package verified: node=$node, package=$package, ${package_status#ii }"
  done

  observed_client_version="$(multipass exec "$node" -- dpkg-query -W -f='${Version}' slurm-client)"
  if [[ -z "$slurm_client_version" ]]; then
    slurm_client_version="$observed_client_version"
  elif [[ "$observed_client_version" != "$slurm_client_version" ]]; then
    log ERROR "Slurm version mismatch: node=$node, expected=$slurm_client_version, observed=$observed_client_version"
    exit 1
  fi

  fingerprint="$(multipass exec "$node" -- sudo sha256sum /etc/munge/munge.key | awk '{print $1}')"
  key_metadata="$(multipass exec "$node" -- sudo stat -c '%U:%G %a' /etc/munge/munge.key)"
  [[ "$key_metadata" == "munge:munge 400" ]] || {
    log ERROR "Invalid MUNGE key metadata: node=$node, expected='munge:munge 400', observed='$key_metadata'"
    exit 1
  }
  if [[ -z "$controller_fingerprint" ]]; then
    controller_fingerprint="$fingerprint"
  elif [[ "$fingerprint" != "$controller_fingerprint" ]]; then
    log ERROR "MUNGE key fingerprint mismatch: node=$node, expected=$controller_fingerprint, observed=$fingerprint"
    exit 1
  fi

  active_state="$(multipass exec "$node" -- systemctl is-active munge)"
  enabled_state="$(multipass exec "$node" -- systemctl is-enabled munge)"
  [[ "$active_state" == active && "$enabled_state" == enabled ]] || {
    log ERROR "MUNGE service check failed: node=$node, active=$active_state, enabled=$enabled_state"
    exit 1
  }
  log INFO "Node foundation verified: node=$node, daemon='$daemon_version', munge=$(multipass exec "$node" -- munge --version | head -n 1), key_sha256=$fingerprint, service=$active_state/$enabled_state"
done
log INFO "All nodes use slurm-client package version $slurm_client_version"

log INFO "Phase 7/7: validate local and cross-node MUNGE authentication"
for node in "${nodes[@]}"; do
  local_status="$(multipass exec "$node" -- sh -c 'munge -n | unmunge | sed -n "s/^STATUS:[[:space:]]*//p"')"
  [[ "$local_status" == "Success (0)" ]] || {
    log ERROR "Local MUNGE round trip failed: node=$node, status='${local_status:-<empty>}'"
    exit 1
  }
  log INFO "Local MUNGE round trip succeeded: $node"
done

for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  credential_report="$(
    multipass exec "$CONTROLLER_NAME" -- munge -n |
      multipass exec "$worker" -- unmunge
  )"
  credential_status="$(printf '%s\n' "$credential_report" | sed -n 's/^STATUS:[[:space:]]*//p')"
  encode_host="$(printf '%s\n' "$credential_report" | sed -n 's/^ENCODE_HOST:[[:space:]]*//p')"
  [[ "$credential_status" == "Success (0)" ]] || {
    log ERROR "Cross-node MUNGE validation failed: controller=$CONTROLLER_NAME, worker=$worker, status='${credential_status:-<empty>}'"
    exit 1
  }
  log INFO "Cross-node credential succeeded: $CONTROLLER_NAME -> $worker, encode_host='$encode_host'"
done

log INFO "Software installation and MUNGE validation passed on all nodes"
