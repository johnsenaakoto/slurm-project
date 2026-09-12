#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
BEGIN_MARKER="# BEGIN SLURM SHARED STORAGE"
END_MARKER="# END SLURM SHARED STORAGE"

usage() {
  cat <<'EOF'
Usage: configure-shared-storage.sh [--config FILE] [--dry-run] [--help]

Configure the controller as a simple NFS server, mount the shared directory on
both workers, and validate cross-node file visibility.
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
init_observability "06-shared-storage" "$LOG_DIR"

SHARED_STORAGE_PATH="${SHARED_STORAGE_PATH:-/shared}"
NFS_CONTROLLER_PACKAGES="${NFS_CONTROLLER_PACKAGES:-nfs-kernel-server}"
NFS_WORKER_PACKAGES="${NFS_WORKER_PACKAGES:-nfs-common}"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME SHARED_STORAGE_PATH
  NFS_CONTROLLER_PACKAGES NFS_WORKER_PACKAGES APT_UPDATE LOG_DIR
)
for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done
[[ "$SHARED_STORAGE_PATH" =~ ^/[a-zA-Z0-9._/-]+$ ]] || {
  log ERROR "SHARED_STORAGE_PATH must be an absolute path without spaces: $SHARED_STORAGE_PATH"
  exit 1
}
[[ "$SHARED_STORAGE_PATH" != "/" ]] || {
  log ERROR "SHARED_STORAGE_PATH cannot be /"
  exit 1
}
[[ "$APT_UPDATE" == "true" || "$APT_UPDATE" == "false" ]] || {
  log ERROR "APT_UPDATE must be true or false; observed: $APT_UPDATE"
  exit 1
}

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
workers=("$WORKER1_NAME" "$WORKER2_NAME")
if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi

read -r -a controller_packages <<<"$NFS_CONTROLLER_PACKAGES"
read -r -a worker_packages <<<"$NFS_WORKER_PACKAGES"
for package in "${controller_packages[@]}" "${worker_packages[@]}"; do
  [[ "$package" =~ ^[a-zA-Z0-9.+-]+$ ]] || {
    log ERROR "Invalid package name in configuration: $package"
    exit 1
  }
done

get_ipv4() {
  local node="$1"
  local address
  address="$(multipass exec "$node" -- hostname -I | awk '{print $1}')"
  [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    log ERROR "Could not discover an IPv4 address for $node: ${address:-<empty>}"
    return 1
  }
  printf '%s' "$address"
}

log INFO "Phase 1/6: verify Multipass instances and discover worker addresses"
if [[ "$DRY_RUN" == true ]]; then
  worker1_ip="<${WORKER1_NAME}-ipv4>"
  worker2_ip="<${WORKER2_NAME}-ipv4>"
  log INFO "Dry run uses placeholder worker addresses; live runs discover them with hostname -I"
else
  for node in "${nodes[@]}"; do
    availability_output="$(multipass exec "$node" -- true 2>&1)" || {
      log ERROR "Multipass instance is not running or is unavailable: $node"
      log ERROR "Multipass output: ${availability_output:-<empty>}"
      exit 1
    }
  done
  worker1_ip="$(get_ipv4 "$WORKER1_NAME")"
  worker2_ip="$(get_ipv4 "$WORKER2_NAME")"
  log INFO "Discovered workers: $WORKER1_NAME=$worker1_ip, $WORKER2_NAME=$worker2_ip"
fi

exports_block="$BEGIN_MARKER
$SHARED_STORAGE_PATH $worker1_ip(rw,sync,no_subtree_check) $worker2_ip(rw,sync,no_subtree_check)
$END_MARKER"
fstab_block="$BEGIN_MARKER
$CONTROLLER_NAME:$SHARED_STORAGE_PATH $SHARED_STORAGE_PATH nfs defaults,_netdev 0 0
$END_MARKER"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Controller packages: $NFS_CONTROLLER_PACKAGES"
  log INFO "Worker packages: $NFS_WORKER_PACKAGES"
  log INFO "Proposed /etc/exports block follows"
  printf '%s\n' "$exports_block"
  log INFO "Proposed worker /etc/fstab block follows"
  printf '%s\n' "$fstab_block"
  log INFO "Dry run finished; no packages, exports, mounts, or files were changed"
  exit 0
fi

log INFO "Phase 2/6: install NFS packages"
if [[ "$APT_UPDATE" == true ]]; then
  for node in "${nodes[@]}"; do
    log INFO "Refreshing APT indexes: $node"
    multipass exec "$node" -- sudo apt-get update
  done
else
  log INFO "APT index refresh disabled by configuration"
fi
multipass exec "$CONTROLLER_NAME" -- sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${controller_packages[@]}"
for worker in "${workers[@]}"; do
  multipass exec "$worker" -- sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${worker_packages[@]}"
done

log INFO "Phase 3/6: create and export $SHARED_STORAGE_PATH from $CONTROLLER_NAME"
multipass exec "$CONTROLLER_NAME" -- sudo install -d -o ubuntu -g ubuntu -m 0775 "$SHARED_STORAGE_PATH"
printf '%s\n' "$exports_block" |
  multipass exec "$CONTROLLER_NAME" -- sudo sh -c \
    "sed -i '/^# BEGIN SLURM SHARED STORAGE$/,/^# END SLURM SHARED STORAGE$/d;\\|^${SHARED_STORAGE_PATH}[[:space:]]|d' /etc/exports; cat >> /etc/exports"
multipass exec "$CONTROLLER_NAME" -- sudo exportfs -ra
multipass exec "$CONTROLLER_NAME" -- sudo systemctl enable --now nfs-server
multipass exec "$CONTROLLER_NAME" -- sudo exportfs -v

log INFO "Phase 4/6: mount shared storage on workers"
for worker in "${workers[@]}"; do
  log INFO "Configuring NFS client mount on $worker"
  current_source="$(multipass exec "$worker" -- findmnt -n -o SOURCE -T "$SHARED_STORAGE_PATH" 2>/dev/null || true)"
  if [[ "$current_source" == "$CONTROLLER_NAME:$SHARED_STORAGE_PATH" || "$current_source" == *":$SHARED_STORAGE_PATH" ]]; then
    log INFO "$SHARED_STORAGE_PATH is already mounted from $current_source on $worker"
  else
    multipass exec "$worker" -- sudo install -d -o root -g root -m 0755 "$SHARED_STORAGE_PATH"
  fi
  printf '%s\n' "$fstab_block" |
    multipass exec "$worker" -- sudo sh -c \
      "sed -i '/^# BEGIN SLURM SHARED STORAGE$/,/^# END SLURM SHARED STORAGE$/d;\\|^[^#][^[:space:]]*[[:space:]]${SHARED_STORAGE_PATH}[[:space:]]|d' /etc/fstab; cat >> /etc/fstab"
  multipass exec "$worker" -- sudo systemctl daemon-reload
  if [[ "$current_source" == "$CONTROLLER_NAME:$SHARED_STORAGE_PATH" || "$current_source" == *":$SHARED_STORAGE_PATH" ]]; then
    log INFO "Skipping remount on $worker because $SHARED_STORAGE_PATH is already available"
  else
    multipass exec "$worker" -- sudo mount "$SHARED_STORAGE_PATH"
  fi
done

log INFO "Phase 5/6: validate NFS mounts and cross-node writes"
run_id="$(date '+%Y%m%d-%H%M%S')-$$"
controller_file="$SHARED_STORAGE_PATH/controller-${run_id}.txt"
worker1_file="$SHARED_STORAGE_PATH/${WORKER1_NAME}-${run_id}.txt"
worker2_file="$SHARED_STORAGE_PATH/${WORKER2_NAME}-${run_id}.txt"
multipass exec "$CONTROLLER_NAME" -- sh -c "printf '%s\n' 'hello from $CONTROLLER_NAME' > '$controller_file'"
for worker in "${workers[@]}"; do
  mount_source="$(multipass exec "$worker" -- findmnt -n -o SOURCE -T "$SHARED_STORAGE_PATH")"
  mount_type="$(multipass exec "$worker" -- findmnt -n -o FSTYPE -T "$SHARED_STORAGE_PATH")"
  [[ "$mount_source" == "$CONTROLLER_NAME:$SHARED_STORAGE_PATH" || "$mount_source" == *":$SHARED_STORAGE_PATH" ]] || {
    log ERROR "$SHARED_STORAGE_PATH is not mounted from the controller on $worker; observed source: ${mount_source:-<empty>}"
    exit 1
  }
  [[ "$mount_type" == nfs* ]] || {
    log ERROR "$SHARED_STORAGE_PATH is not mounted as NFS on $worker; observed type: ${mount_type:-<empty>}"
    exit 1
  }
  multipass exec "$worker" -- test -r "$controller_file"
  multipass exec "$worker" -- sh -c "printf '%s\n' 'hello from $worker' > '$SHARED_STORAGE_PATH/$worker-${run_id}.txt'"
  log INFO "NFS mount verified on $worker: source=$mount_source, type=$mount_type"
done
multipass exec "$CONTROLLER_NAME" -- test -r "$worker1_file"
multipass exec "$CONTROLLER_NAME" -- test -r "$worker2_file"

log INFO "Phase 6/6: summarize shared storage contents"
multipass exec "$CONTROLLER_NAME" -- ls -l "$SHARED_STORAGE_PATH"
log INFO "Shared NFS storage is available at $SHARED_STORAGE_PATH on both workers"
