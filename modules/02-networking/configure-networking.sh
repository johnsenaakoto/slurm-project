#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
BEGIN_MARKER="# BEGIN SLURM CLUSTER NODES"
END_MARKER="# END SLURM CLUSTER NODES"

usage() {
  cat <<'EOF'
Usage: configure-networking.sh [--config FILE] [--dry-run] [--help]

Configure hostname resolution and verify connectivity, Ubuntu identity, and
clock synchronization across the Multipass cluster.
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
init_observability "02-networking" "$LOG_DIR"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME
  EXPECTED_OS_ID EXPECTED_VERSION_ID PING_COUNT
  MAX_CLOCK_SKEW_SECONDS REQUIRE_NTP_SYNC
  LOG_DIR
)

for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done

[[ "$PING_COUNT" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "PING_COUNT must be a positive integer; observed: $PING_COUNT"
  exit 1
}
[[ "$MAX_CLOCK_SKEW_SECONDS" =~ ^[0-9]+$ ]] || {
  log ERROR "MAX_CLOCK_SKEW_SECONDS must be a non-negative integer; observed: $MAX_CLOCK_SKEW_SECONDS"
  exit 1
}
[[ "$REQUIRE_NTP_SYNC" == "true" || "$REQUIRE_NTP_SYNC" == "false" ]] || {
  log ERROR "REQUIRE_NTP_SYNC must be true or false; observed: $REQUIRE_NTP_SYNC"
  exit 1
}

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
if [[ "$CONTROLLER_NAME" == "$WORKER1_NAME" ||
      "$CONTROLLER_NAME" == "$WORKER2_NAME" ||
      "$WORKER1_NAME" == "$WORKER2_NAME" ]]; then
  log ERROR "Every node must have a unique name"
  exit 1
fi

node_ips=()

log INFO "Phase 1/5: discover cluster addresses"
for node in "${nodes[@]}"; do
  multipass info "$node" >/dev/null 2>&1 || {
    log ERROR "Multipass instance does not exist or is unavailable: $node"
    exit 1
  }

  ip="$(multipass exec "$node" -- hostname -I | awk '{print $1}')"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    log ERROR "Could not discover an IPv4 address for $node; hostname -I returned: ${ip:-<empty>}"
    exit 1
  }
  node_ips+=("$ip")
  log INFO "Discovered: node=$node, ipv4=$ip"
done

hosts_block="$BEGIN_MARKER"
for index in "${!nodes[@]}"; do
  hosts_block+=$'\n'"${node_ips[$index]} ${nodes[$index]}"
done
hosts_block+=$'\n'"$END_MARKER"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Proposed managed /etc/hosts block follows"
  echo "$hosts_block"
  log INFO "Dry run finished; no guest files were changed"
  exit 0
fi

log INFO "Phase 2/5: update the managed /etc/hosts block"
for node in "${nodes[@]}"; do
  log INFO "Updating /etc/hosts on $node"
  printf '%s\n' "$hosts_block" | multipass exec "$node" -- sudo sh -c \
    'sed -i "/^# BEGIN SLURM CLUSTER NODES$/,/^# END SLURM CLUSTER NODES$/d" /etc/hosts; cat >> /etc/hosts'
  managed_block="$(multipass exec "$node" -- sed -n "/^# BEGIN SLURM CLUSTER NODES$/,/^# END SLURM CLUSTER NODES$/p" /etc/hosts)"
  [[ "$managed_block" == "$hosts_block" ]] || {
    log ERROR "Post-write verification failed for $node; managed /etc/hosts block does not match"
    log ERROR "Expected block: $hosts_block"
    log ERROR "Observed block: ${managed_block:-<empty>}"
    exit 1
  }
  log INFO "Updated and read-back verified: $node"
done

log INFO "Phase 3/5: verify hostname and Ubuntu identity"
for node in "${nodes[@]}"; do
  identity="$(multipass exec "$node" -- sh -c '. /etc/os-release; printf "%s %s" "$ID" "$VERSION_ID"')"
  hostname="$(multipass exec "$node" -- hostname)"
  [[ "$hostname" == "$node" ]] || {
    log ERROR "Hostname mismatch: node=$node, expected=$node, observed=$hostname"
    exit 1
  }
  [[ "$identity" == "$EXPECTED_OS_ID $EXPECTED_VERSION_ID" ]] || {
    log ERROR "OS identity mismatch: node=$node, expected='$EXPECTED_OS_ID $EXPECTED_VERSION_ID', observed='$identity'"
    exit 1
  }
  log INFO "Identity verified: node=$node, hostname=$hostname, os='$identity'"
done

log INFO "Phase 4/5: verify name resolution and all-to-all connectivity"
for source_node in "${nodes[@]}"; do
  for target_index in "${!nodes[@]}"; do
    target_node="${nodes[$target_index]}"
    expected_ip="${node_ips[$target_index]}"
    resolved_ips="$(multipass exec "$source_node" -- getent ahostsv4 "$target_node" | awk '{print $1}' | sort -u)"
    grep -Fxq "$expected_ip" <<<"$resolved_ips" || {
      log ERROR "Resolution mismatch: source=$source_node, target=$target_node, expected=$expected_ip, observed=${resolved_ips:-<empty>}"
      exit 1
    }
    if ! ping_output="$(multipass exec "$source_node" -- ping -q -c "$PING_COUNT" -W 2 "$target_node" 2>&1)"; then
      log ERROR "Ping failed: source=$source_node, target=$target_node, expected_ip=$expected_ip"
      log ERROR "Ping output: $ping_output"
      exit 1
    fi
    packet_summary="$(printf '%s\n' "$ping_output" | tail -n 2 | tr '\n' ' ')"
    log INFO "Connectivity verified: $source_node -> $target_node ($expected_ip); $packet_summary"
  done
done

log INFO "Phase 5/5: verify NTP status and clock skew"
minimum_epoch=""
maximum_epoch=""
for node in "${nodes[@]}"; do
  epoch="$(multipass exec "$node" -- date +%s)"
  ntp_synced="$(multipass exec "$node" -- timedatectl show --property=NTPSynchronized --value)"
  timezone="$(multipass exec "$node" -- timedatectl show --property=Timezone --value)"

  if [[ "$REQUIRE_NTP_SYNC" == "true" && "$ntp_synced" != "yes" ]]; then
    log ERROR "NTP synchronization check failed: node=$node, NTPSynchronized=$ntp_synced"
    exit 1
  fi

  [[ -n "$minimum_epoch" && "$epoch" -ge "$minimum_epoch" ]] || minimum_epoch="$epoch"
  [[ -n "$maximum_epoch" && "$epoch" -le "$maximum_epoch" ]] || maximum_epoch="$epoch"
  iso_time="$(multipass exec "$node" -- date --iso-8601=seconds)"
  log INFO "Clock observed: node=$node, epoch=$epoch, time=$iso_time, ntp-synchronized=$ntp_synced, timezone=$timezone"
done

clock_skew=$((maximum_epoch - minimum_epoch))
((clock_skew <= MAX_CLOCK_SKEW_SECONDS)) || {
  log ERROR "Clock skew exceeded: observed=${clock_skew}s, maximum=${MAX_CLOCK_SKEW_SECONDS}s"
  exit 1
}

log INFO "Networking and node foundation checks passed (clock skew=${clock_skew}s)"
