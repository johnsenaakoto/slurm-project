#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
ACCOUNTING_FRAGMENT_FILE=""

usage() {
  cat <<'EOF'
Usage: configure-accounting-db.sh [--config FILE] [--dry-run] [--help]

Install and configure Slurm database accounting with MariaDB and slurmdbd,
then submit demonstration jobs and verify their records through sacct and SQL.
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
init_observability "10-accounting-db" "$LOG_DIR"

ACCOUNTING_DB_NAME="${ACCOUNTING_DB_NAME:-slurm_acct_db}"
ACCOUNTING_DB_USER="${ACCOUNTING_DB_USER:-slurm}"
ACCOUNTING_DB_AUTH="${ACCOUNTING_DB_AUTH:-}"
ACCOUNTING_DB_AUTH_FILE="${ACCOUNTING_DB_AUTH_FILE:-/etc/slurm/slurmdbd-mysql.auth}"
ACCOUNTING_ACCOUNT="${ACCOUNTING_ACCOUNT:-lab}"
ACCOUNTING_TEST_DIR="${ACCOUNTING_TEST_DIR:-/shared/accounting-lab}"
ACCOUNTING_JOB_TIMEOUT_SECONDS="${ACCOUNTING_JOB_TIMEOUT_SECONDS:-180}"
ACCOUNTING_PACKAGES="${ACCOUNTING_PACKAGES:-mariadb-server slurmdbd}"
ACCOUNTING_DEMO_USER="${ACCOUNTING_DEMO_USER:-ubuntu}"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME CLUSTER_NAME PARTITION_NAME
  APT_UPDATE ACCOUNTING_DB_NAME ACCOUNTING_DB_USER ACCOUNTING_DB_AUTH_FILE
  ACCOUNTING_ACCOUNT ACCOUNTING_DEMO_USER ACCOUNTING_TEST_DIR
  ACCOUNTING_JOB_TIMEOUT_SECONDS ACCOUNTING_PACKAGES LOG_DIR
)
for variable in "${required_variables[@]}"; do
  [[ -n "${!variable:-}" ]] || {
    log ERROR "$variable is missing or empty in $CONFIG_FILE"
    exit 1
  }
done
for name_variable in CONTROLLER_NAME WORKER1_NAME WORKER2_NAME CLUSTER_NAME PARTITION_NAME ACCOUNTING_DB_NAME ACCOUNTING_DB_USER ACCOUNTING_ACCOUNT ACCOUNTING_DEMO_USER; do
  [[ "${!name_variable}" =~ ^[a-zA-Z0-9_-]+$ ]] || {
    log ERROR "$name_variable contains unsupported characters: ${!name_variable}"
    exit 1
  }
done
[[ "$ACCOUNTING_TEST_DIR" == /* ]] || {
  log ERROR "ACCOUNTING_TEST_DIR must be an absolute path"
  exit 1
}
[[ "$ACCOUNTING_DB_AUTH_FILE" == /* ]] || {
  log ERROR "ACCOUNTING_DB_AUTH_FILE must be an absolute path"
  exit 1
}
[[ "$ACCOUNTING_JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "ACCOUNTING_JOB_TIMEOUT_SECONDS must be a positive integer"
  exit 1
}

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
job_ids=()

mysql_literal() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
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

submit_inline_job() {
  local script="$1"
  local submission

  submission="$(printf '%s\n' "$script" | multipass exec "$CONTROLLER_NAME" -- sbatch --parsable)"
  submission="${submission%%;*}"
  [[ "$submission" =~ ^[0-9]+$ ]] || {
    log ERROR "Could not parse submitted job ID: $submission"
    exit 1
  }
  job_ids+=("$submission")
  printf '%s\n' "$submission"
}

wait_for_terminal_state() {
  local job_id="$1"
  local expected_state="$2"
  local expected_exit="$3"
  local deadline=$((SECONDS + ACCOUNTING_JOB_TIMEOUT_SECONDS))
  local report state exit_code

  while true; do
    report="$(job_report "$job_id")"
    state="$(job_field JobState "$report")"
    exit_code="$(job_field ExitCode "$report")"
    if [[ "$state" == "$expected_state" ]]; then
      [[ "$exit_code" == "$expected_exit" ]] || {
        log ERROR "Job $job_id reached $state but had unexpected ExitCode=${exit_code:-<empty>}"
        log ERROR "Job report: $report"
        exit 1
      }
      return 0
    fi
    case "$state" in
      COMPLETED|FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|SPECIAL_EXIT)
        log ERROR "Job $job_id reached $state while waiting for $expected_state"
        log ERROR "Job report: $report"
        exit 1
        ;;
    esac
    if ((SECONDS >= deadline)); then
      multipass exec "$CONTROLLER_NAME" -- scancel "$job_id" >/dev/null 2>&1 || true
      log ERROR "Job $job_id did not reach $expected_state within ${ACCOUNTING_JOB_TIMEOUT_SECONDS}s"
      log ERROR "Last job report: $report"
      exit 1
    fi
    sleep 1
  done
}

wait_for_sacct_record() {
  local job_id="$1"
  local deadline=$((SECONDS + ACCOUNTING_JOB_TIMEOUT_SECONDS))
  local rows

  while true; do
    rows="$(multipass exec "$CONTROLLER_NAME" -- sacct -n -X -j "$job_id" -o JobIDRaw 2>/dev/null | awk '{$1=$1; print}' || true)"
    if grep -Fxq "$job_id" <<<"$rows"; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      log ERROR "sacct did not return job $job_id within ${ACCOUNTING_JOB_TIMEOUT_SECONDS}s"
      exit 1
    fi
    sleep 1
  done
}

module_cleanup() {
  local exit_code="$1"

  if [[ -n "$ACCOUNTING_FRAGMENT_FILE" ]]; then
    rm -f -- "$ACCOUNTING_FRAGMENT_FILE"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  if ((${#job_ids[@]} > 0)); then
    multipass exec "$CONTROLLER_NAME" -- scancel "${job_ids[@]}" >/dev/null 2>&1 || true
  fi
  if ((exit_code != 0)); then
    log INFO "Cancelled any still-active accounting demonstration jobs"
  fi
}

slurm_accounting_configuration="AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=$CONTROLLER_NAME
JobAcctGatherType=jobacct_gather/linux
JobAcctGatherFrequency=30"

success_job="#!/bin/bash
#SBATCH --job-name=acct-success
#SBATCH --account=$ACCOUNTING_ACCOUNT
#SBATCH --partition=$PARTITION_NAME
#SBATCH --output=$ACCOUNTING_TEST_DIR/success-%j.out
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:02:00

set -euo pipefail
echo \"SUCCESS job=\$SLURM_JOB_ID account=\$SLURM_JOB_ACCOUNT node=\$SLURM_JOB_NODELIST\"
sleep 5
exit 0"

fail_job="#!/bin/bash
#SBATCH --job-name=acct-fail
#SBATCH --account=$ACCOUNTING_ACCOUNT
#SBATCH --partition=$PARTITION_NAME
#SBATCH --output=$ACCOUNTING_TEST_DIR/fail-%j.out
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:02:00

echo \"FAIL job=\$SLURM_JOB_ID account=\$SLURM_JOB_ACCOUNT node=\$SLURM_JOB_NODELIST\"
exit 7"

cpu_job="#!/bin/bash
#SBATCH --job-name=acct-cpus
#SBATCH --account=$ACCOUNTING_ACCOUNT
#SBATCH --partition=$PARTITION_NAME
#SBATCH --output=$ACCOUNTING_TEST_DIR/cpus-%j.out
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:02:00

set -euo pipefail
echo \"CPUS job=\$SLURM_JOB_ID account=\$SLURM_JOB_ACCOUNT cpus=\$SLURM_CPUS_PER_TASK node=\$SLURM_JOB_NODELIST\"
sleep 10
exit 0"

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Dry run plan follows"
  log INFO "Would install packages on $CONTROLLER_NAME: $ACCOUNTING_PACKAGES"
  log INFO "Would create MariaDB database '$ACCOUNTING_DB_NAME' and user '$ACCOUNTING_DB_USER'"
  log INFO "Would use an existing ACCOUNTING_DB_AUTH or generate one in $ACCOUNTING_DB_AUTH_FILE"
  log INFO "Would write /etc/slurm/slurmdbd.conf and start mariadb + slurmdbd"
  log INFO "Would add accounting settings to /etc/slurm/slurm.conf on all nodes"
  log INFO "Would register cluster=$CLUSTER_NAME account=$ACCOUNTING_ACCOUNT user=$ACCOUNTING_DEMO_USER"
  log INFO "Would submit acct-success, acct-fail, and acct-cpus jobs and query sacct + MariaDB"
  log INFO "Dry run finished; no guests, services, databases, or jobs were changed"
  exit 0
fi

log INFO "Phase 1/8: verify Multipass guests and Slurm services"
for node in "${nodes[@]}"; do
  multipass info "$node" >/dev/null 2>&1 || {
    log ERROR "Multipass instance does not exist or is unavailable: $node"
    exit 1
  }
done
multipass exec "$CONTROLLER_NAME" -- scontrol ping

log INFO "Phase 2/8: install accounting packages on $CONTROLLER_NAME"
if [[ "$APT_UPDATE" == true ]]; then
  multipass exec "$CONTROLLER_NAME" -- sudo apt-get update
fi
multipass exec "$CONTROLLER_NAME" -- sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $ACCOUNTING_PACKAGES

log INFO "Phase 3/8: create MariaDB database and local Slurm database user"
multipass exec "$CONTROLLER_NAME" -- sudo systemctl enable --now mariadb
if [[ -z "$ACCOUNTING_DB_AUTH" ]]; then
  multipass exec "$CONTROLLER_NAME" -- sudo sh -c '
    set -e
    auth_file="$1"
    if [ ! -s "$auth_file" ]; then
      umask 077
      openssl rand -hex 24 >"$auth_file"
      chown slurm:slurm "$auth_file"
      chmod 600 "$auth_file"
    fi
  ' sh "$ACCOUNTING_DB_AUTH_FILE"
  ACCOUNTING_DB_AUTH="$(multipass exec "$CONTROLLER_NAME" -- sudo cat "$ACCOUNTING_DB_AUTH_FILE")"
fi
db_user_literal="$(mysql_literal "$ACCOUNTING_DB_USER")"
db_auth_literal="$(mysql_literal "$ACCOUNTING_DB_AUTH")"
multipass exec "$CONTROLLER_NAME" -- sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`$ACCOUNTING_DB_NAME\`;"
multipass exec "$CONTROLLER_NAME" -- sudo mysql -e "CREATE USER IF NOT EXISTS $db_user_literal@'localhost' IDENTIFIED BY $db_auth_literal;"
multipass exec "$CONTROLLER_NAME" -- sudo mysql -e "ALTER USER $db_user_literal@'localhost' IDENTIFIED BY $db_auth_literal;"
multipass exec "$CONTROLLER_NAME" -- sudo mysql -e "GRANT ALL ON \`$ACCOUNTING_DB_NAME\`.* TO $db_user_literal@'localhost'; FLUSH PRIVILEGES;"

log INFO "Phase 4/8: configure and start slurmdbd"
slurmdbd_configuration="AuthType=auth/munge
DbdAddr=$CONTROLLER_NAME
DbdHost=$CONTROLLER_NAME
DbdPort=6819
SlurmUser=slurm
DebugLevel=info
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd/slurmdbd.pid
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=$ACCOUNTING_DB_USER
StoragePass=$ACCOUNTING_DB_AUTH
StorageLoc=$ACCOUNTING_DB_NAME"
printf '%s\n' "$slurmdbd_configuration" |
  multipass exec "$CONTROLLER_NAME" -- sudo sh -c 'install -d -o root -g root -m 0755 /etc/slurm; install -o slurm -g slurm -m 0600 /dev/stdin /etc/slurm/slurmdbd.conf'
multipass exec "$CONTROLLER_NAME" -- sudo install -o slurm -g slurm -m 0644 /dev/null /var/log/slurm/slurmdbd.log
multipass exec "$CONTROLLER_NAME" -- sudo systemctl daemon-reload
multipass exec "$CONTROLLER_NAME" -- sudo systemctl enable slurmdbd
multipass exec "$CONTROLLER_NAME" -- sudo systemctl restart slurmdbd

log INFO "Phase 5/8: enable Slurm accounting settings on all nodes"
ACCOUNTING_FRAGMENT_FILE="$(mktemp "${TMPDIR:-/tmp}/slurm-accounting-conf.XXXXXX")"
printf '\n%s\n' "$slurm_accounting_configuration" >"$ACCOUNTING_FRAGMENT_FILE"
for node in "${nodes[@]}"; do
  multipass exec "$node" -- sudo sed -i \
    -e '/^AccountingStorageType=/d' \
    -e '/^AccountingStorageHost=/d' \
    -e '/^JobAcctGatherType=/d' \
    -e '/^JobAcctGatherFrequency=/d' \
    /etc/slurm/slurm.conf
  multipass transfer "$ACCOUNTING_FRAGMENT_FILE" "$node:/tmp/slurm-accounting.conf"
  multipass exec "$node" -- sudo sh -c 'cat /tmp/slurm-accounting.conf >> /etc/slurm/slurm.conf; rm -f /tmp/slurm-accounting.conf'
done
rm -f -- "$ACCOUNTING_FRAGMENT_FILE"
ACCOUNTING_FRAGMENT_FILE=""
multipass exec "$CONTROLLER_NAME" -- sudo systemctl restart slurmctld
for worker in "$WORKER1_NAME" "$WORKER2_NAME"; do
  multipass exec "$worker" -- sudo systemctl restart slurmd
done

log INFO "Phase 6/8: register cluster, account, and user associations"
multipass exec "$CONTROLLER_NAME" -- timeout 30s sudo sacctmgr -i add cluster "$CLUSTER_NAME" || true
multipass exec "$CONTROLLER_NAME" -- timeout 30s sudo sacctmgr -i add account "$ACCOUNTING_ACCOUNT" Description=Lab_account Organization=local || true
multipass exec "$CONTROLLER_NAME" -- timeout 30s sudo sacctmgr -i add user "$ACCOUNTING_DEMO_USER" "account=$ACCOUNTING_ACCOUNT" || true
multipass exec "$CONTROLLER_NAME" -- timeout 30s sacctmgr show assoc

log INFO "Phase 7/8: submit accounting demonstration jobs"
multipass exec "$CONTROLLER_NAME" -- mkdir -p "$ACCOUNTING_TEST_DIR"
success_id="$(submit_inline_job "$success_job")"
fail_id="$(submit_inline_job "$fail_job")"
cpu_id="$(submit_inline_job "$cpu_job")"
log INFO "Submitted jobs: success=$success_id fail=$fail_id cpus=$cpu_id"
wait_for_terminal_state "$success_id" COMPLETED "0:0"
wait_for_terminal_state "$fail_id" FAILED "7:0"
wait_for_terminal_state "$cpu_id" COMPLETED "0:0"
job_ids=()

log INFO "Phase 8/8: verify sacct and MariaDB accounting records"
for job_id in "$success_id" "$fail_id" "$cpu_id"; do
  wait_for_sacct_record "$job_id"
done
multipass exec "$CONTROLLER_NAME" -- sacct -j "${success_id},${fail_id},${cpu_id}" -X -o JobID,JobName,Account,State,ExitCode,Elapsed,AllocCPUS,ReqCPUS,NodeList
table_name="${CLUSTER_NAME}_job_table"
multipass exec "$CONTROLLER_NAME" -- sudo mysql "$ACCOUNTING_DB_NAME" -e "
SELECT
  id_job,
  job_name,
  account,
  \`partition\`,
  cpus_req,
  nodes_alloc,
  nodelist,
  state,
  exit_code,
  FROM_UNIXTIME(time_submit) AS submitted,
  FROM_UNIXTIME(time_start) AS started,
  FROM_UNIXTIME(time_end) AS ended,
  tres_req,
  tres_alloc
FROM \`$table_name\`
WHERE id_job IN ($success_id, $fail_id, $cpu_id)
ORDER BY id_job;
"

log INFO "Accounting database lab completed successfully"
