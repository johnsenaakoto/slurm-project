#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/config/cluster.env"
DRY_RUN=false
ARRAY_JOB_ID=""
SUMMARY_JOB_ID=""

usage() {
  cat <<'EOF'
Usage: run-arrays-and-dependencies.sh [--config FILE] [--dry-run] [--help]

Run a small Slurm job array, submit a summary job with an afterok dependency,
and validate the fan-out/fan-in workflow through shared storage.
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
init_observability "07-arrays-and-dependencies" "$LOG_DIR"

SHARED_STORAGE_PATH="${SHARED_STORAGE_PATH:-/shared}"
ARRAY_TASK_COUNT="${ARRAY_TASK_COUNT:-5}"
ARRAY_JOB_TIMEOUT_SECONDS="${ARRAY_JOB_TIMEOUT_SECONDS:-180}"
ARRAY_DEMO_DIR="${ARRAY_DEMO_DIR:-$SHARED_STORAGE_PATH/arrays-demo}"

required_variables=(
  CONTROLLER_NAME WORKER1_NAME WORKER2_NAME PARTITION_NAME
  SHARED_STORAGE_PATH ARRAY_TASK_COUNT ARRAY_JOB_TIMEOUT_SECONDS ARRAY_DEMO_DIR LOG_DIR
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
[[ "$ARRAY_DEMO_DIR" =~ ^/[a-zA-Z0-9._/-]+$ ]] || {
  log ERROR "ARRAY_DEMO_DIR must be an absolute path without spaces: $ARRAY_DEMO_DIR"
  exit 1
}
[[ "$ARRAY_TASK_COUNT" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "ARRAY_TASK_COUNT must be a positive integer"
  exit 1
}
((ARRAY_TASK_COUNT <= 50)) || {
  log ERROR "ARRAY_TASK_COUNT is intentionally capped at 50 for this learning module"
  exit 1
}
[[ "$ARRAY_JOB_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
  log ERROR "ARRAY_JOB_TIMEOUT_SECONDS must be a positive integer"
  exit 1
}
[[ "$PARTITION_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] || {
  log ERROR "PARTITION_NAME contains unsupported characters: $PARTITION_NAME"
  exit 1
}

nodes=("$CONTROLLER_NAME" "$WORKER1_NAME" "$WORKER2_NAME")
workers=("$WORKER1_NAME" "$WORKER2_NAME")
last_task=$((ARRAY_TASK_COUNT - 1))

array_script="$ARRAY_DEMO_DIR/array-worker.sh"
summary_script="$ARRAY_DEMO_DIR/summarize.sh"

module_cleanup() {
  local exit_code="$1"

  if [[ "$DRY_RUN" == true || "$exit_code" == 0 ]]; then
    return 0
  fi
  if [[ -n "$SUMMARY_JOB_ID" ]]; then
    multipass exec "$CONTROLLER_NAME" -- scancel "$SUMMARY_JOB_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ARRAY_JOB_ID" ]]; then
    multipass exec "$CONTROLLER_NAME" -- scancel "$ARRAY_JOB_ID" >/dev/null 2>&1 || true
  fi
  log INFO "Cancelled submitted jobs from failed run: array=${ARRAY_JOB_ID:-none}, summary=${SUMMARY_JOB_ID:-none}"
}

array_job_script="#!/bin/bash
#SBATCH --job-name=array-worker
#SBATCH --partition=$PARTITION_NAME
#SBATCH --array=0-$last_task
#SBATCH --time=00:03:00
#SBATCH --output=$ARRAY_DEMO_DIR/logs/array-%A_%a.out
#SBATCH --error=$ARRAY_DEMO_DIR/logs/array-%A_%a.err

set -euo pipefail

TASK_ID=\"\$SLURM_ARRAY_TASK_ID\"
INPUT=\"$ARRAY_DEMO_DIR/inputs/input-\${TASK_ID}.txt\"
OUTPUT=\"$ARRAY_DEMO_DIR/outputs/output-\${TASK_ID}.txt\"

echo \"=== Slurm array task started ===\"
echo \"Array job ID:      \$SLURM_ARRAY_JOB_ID\"
echo \"Array task ID:     \$TASK_ID\"
echo \"Full job ID:       \$SLURM_JOB_ID\"
echo \"Node:              \$(hostname)\"
echo \"Allocated nodes:   \$SLURM_JOB_NODELIST\"
echo \"Started at:        \$(date)\"
echo

SHARED_TYPE=\"\$(findmnt -n -o FSTYPE -T $SHARED_STORAGE_PATH)\"
[[ \"\$SHARED_TYPE\" == nfs* ]] || {
  echo \"ERROR: $SHARED_STORAGE_PATH is not mounted as NFS on \$(hostname); observed type=\${SHARED_TYPE:-none}\"
  exit 1
}

INPUT_TEXT=\"\$(cat \"\$INPUT\")\"
SLEEP_SECONDS=\$((5 + TASK_ID * 2))

echo \"Processing input:  \$INPUT_TEXT\"
echo \"Sleeping for:      \${SLEEP_SECONDS}s\"
sleep \"\$SLEEP_SECONDS\"

WORD_COUNT=\"\$(wc -w < \"\$INPUT\" | tr -d ' ')\"
BYTE_COUNT=\"\$(wc -c < \"\$INPUT\" | tr -d ' ')\"
CHECKSUM=\"\$(sha256sum \"\$INPUT\" | awk '{print \$1}')\"

cat > \"\$OUTPUT\" <<EOF
task_id=\$TASK_ID
array_job_id=\$SLURM_ARRAY_JOB_ID
job_id=\$SLURM_JOB_ID
node=\$(hostname)
input_text=\$INPUT_TEXT
word_count=\$WORD_COUNT
byte_count=\$BYTE_COUNT
sha256=\$CHECKSUM
runtime_seconds=\$SLEEP_SECONDS
finished_at=\$(date)
EOF

echo \"Wrote result file: \$OUTPUT\"
echo \"=== Slurm array task completed ===\""

summary_job_script="#!/bin/bash
#SBATCH --job-name=array-summary
#SBATCH --partition=$PARTITION_NAME
#SBATCH --time=00:02:00
#SBATCH --output=$ARRAY_DEMO_DIR/logs/summary-%j.out
#SBATCH --error=$ARRAY_DEMO_DIR/logs/summary-%j.err

set -euo pipefail

SUMMARY=\"$ARRAY_DEMO_DIR/outputs/summary.txt\"

echo \"=== Slurm dependency summary started ===\"
echo \"Summary job ID:    \$SLURM_JOB_ID\"
echo \"Node:              \$(hostname)\"
echo \"Started at:        \$(date)\"
echo

SHARED_TYPE=\"\$(findmnt -n -o FSTYPE -T $SHARED_STORAGE_PATH)\"
[[ \"\$SHARED_TYPE\" == nfs* ]] || {
  echo \"ERROR: $SHARED_STORAGE_PATH is not mounted as NFS on \$(hostname); observed type=\${SHARED_TYPE:-none}\"
  exit 1
}

cat $ARRAY_DEMO_DIR/outputs/output-*.txt > \"\$SUMMARY\"
echo \"Summary written to \$SUMMARY\"
echo
cat \"\$SUMMARY\"
echo
echo \"=== Slurm dependency summary completed ===\""

if [[ "$DRY_RUN" == true ]]; then
  log INFO "Array script that would be installed at $array_script follows"
  printf '%s\n' "$array_job_script"
  log INFO "Summary script that would be installed at $summary_script follows"
  printf '%s\n' "$summary_job_script"
  log INFO "Dry run finished; no shared files or Slurm jobs were created"
  exit 0
fi

job_state() {
  local job_id="$1"
  local report
  report="$(multipass exec "$CONTROLLER_NAME" -- scontrol show job -o "$job_id" 2>/dev/null || true)"
  sed -n 's/.*JobState=\([^ ]*\).*/\1/p' <<<"$report"
}

job_reason() {
  local job_id="$1"
  local report
  report="$(multipass exec "$CONTROLLER_NAME" -- scontrol show job -o "$job_id" 2>/dev/null || true)"
  sed -n 's/.*Reason=\([^ ]*\).*/\1/p' <<<"$report"
}

log INFO "Phase 1/6: verify cluster readiness and shared storage"
for node in "${nodes[@]}"; do
  availability_output="$(multipass exec "$node" -- true 2>&1)" || {
    log ERROR "Multipass instance is not running or is unavailable: $node"
    log ERROR "Multipass output: ${availability_output:-<empty>}"
    exit 1
  }
done
for worker in "${workers[@]}"; do
  state="$(multipass exec "$CONTROLLER_NAME" -- sinfo -h -N -n "$worker" -o '%T')"
  case "$state" in
    idle|mixed|allocated)
      log INFO "Worker is schedulable: node=$worker, state=$state"
      ;;
    *)
      log ERROR "Worker is not in a schedulable state: node=$worker, state=${state:-<empty>}"
      exit 1
      ;;
  esac
  shared_type="$(multipass exec "$worker" -- findmnt -n -o FSTYPE -T "$SHARED_STORAGE_PATH" 2>/dev/null || true)"
  [[ "$shared_type" == nfs* ]] || {
    log ERROR "$SHARED_STORAGE_PATH is not mounted as NFS on $worker; observed type: ${shared_type:-<empty>}. Run module 06 first."
    exit 1
  }
done

log INFO "Phase 2/6: prepare demo inputs and job scripts in $ARRAY_DEMO_DIR"
multipass exec "$CONTROLLER_NAME" -- mkdir -p "$ARRAY_DEMO_DIR/inputs" "$ARRAY_DEMO_DIR/outputs" "$ARRAY_DEMO_DIR/logs"
multipass exec "$CONTROLLER_NAME" -- rm -f "$ARRAY_DEMO_DIR"/inputs/input-*.txt "$ARRAY_DEMO_DIR"/outputs/output-*.txt "$ARRAY_DEMO_DIR"/outputs/summary.txt
for task_id in $(seq 0 "$last_task"); do
  input_text="process dataset shard $task_id for the Slurm array dependency lab"
  multipass exec "$CONTROLLER_NAME" -- sh -c "printf '%s\n' '$input_text' > '$ARRAY_DEMO_DIR/inputs/input-$task_id.txt'"
done
printf '%s\n' "$array_job_script" | multipass exec "$CONTROLLER_NAME" -- sh -c "cat > '$array_script' && chmod +x '$array_script'"
printf '%s\n' "$summary_job_script" | multipass exec "$CONTROLLER_NAME" -- sh -c "cat > '$summary_script' && chmod +x '$summary_script'"

log INFO "Phase 3/6: submit the array job"
submission="$(multipass exec "$CONTROLLER_NAME" -- sbatch --parsable "$array_script")"
ARRAY_JOB_ID="${submission%%;*}"
[[ "$ARRAY_JOB_ID" =~ ^[0-9]+$ ]] || {
  log ERROR "Could not parse array job ID: $submission"
  exit 1
}
log INFO "Submitted array job $ARRAY_JOB_ID with tasks 0-$last_task"

log INFO "Phase 4/6: submit an afterok summary dependency"
submission="$(multipass exec "$CONTROLLER_NAME" -- sbatch --parsable --dependency="afterok:$ARRAY_JOB_ID" "$summary_script")"
SUMMARY_JOB_ID="${submission%%;*}"
[[ "$SUMMARY_JOB_ID" =~ ^[0-9]+$ ]] || {
  log ERROR "Could not parse summary job ID: $submission"
  exit 1
}
log INFO "Submitted summary job $SUMMARY_JOB_ID afterok:$ARRAY_JOB_ID"

log INFO "Phase 5/6: wait for array and summary completion"
deadline=$((SECONDS + ARRAY_JOB_TIMEOUT_SECONDS))
while true; do
  array_state="$(job_state "$ARRAY_JOB_ID")"
  summary_state="$(job_state "$SUMMARY_JOB_ID")"
  array_reason="$(job_reason "$ARRAY_JOB_ID")"
  summary_reason="$(job_reason "$SUMMARY_JOB_ID")"

  if [[ "$array_reason" == InvalidAccount || "$summary_reason" == InvalidAccount ]]; then
    log ERROR "A job is pending with InvalidAccount. Check Slurm accounting enforcement or account associations."
    multipass exec "$CONTROLLER_NAME" -- squeue || true
    exit 1
  fi
  case "$array_state" in
    FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE)
      log ERROR "Array job $ARRAY_JOB_ID ended in state $array_state"
      multipass exec "$CONTROLLER_NAME" -- scontrol show job "$ARRAY_JOB_ID" || true
      exit 1
      ;;
  esac
  case "$summary_state" in
    COMPLETED)
      break
      ;;
    FAILED|CANCELLED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|BOOT_FAIL|DEADLINE|SPECIAL_EXIT)
      log ERROR "Summary job $SUMMARY_JOB_ID ended in state $summary_state"
      multipass exec "$CONTROLLER_NAME" -- scontrol show job "$SUMMARY_JOB_ID" || true
      exit 1
      ;;
  esac
  if ((SECONDS >= deadline)); then
    log ERROR "Jobs did not complete within ${ARRAY_JOB_TIMEOUT_SECONDS}s"
    multipass exec "$CONTROLLER_NAME" -- squeue || true
    multipass exec "$CONTROLLER_NAME" -- scontrol show job "$ARRAY_JOB_ID" || true
    multipass exec "$CONTROLLER_NAME" -- scontrol show job "$SUMMARY_JOB_ID" || true
    exit 1
  fi
  sleep 2
done

log INFO "Phase 6/6: validate array outputs and dependency summary"
for task_id in $(seq 0 "$last_task"); do
  output_file="$ARRAY_DEMO_DIR/outputs/output-$task_id.txt"
  multipass exec "$CONTROLLER_NAME" -- test -s "$output_file" || {
    log ERROR "Missing array task output: $output_file"
    exit 1
  }
  log INFO "Verified array output: $output_file"
done
summary_file="$ARRAY_DEMO_DIR/outputs/summary.txt"
multipass exec "$CONTROLLER_NAME" -- test -s "$summary_file" || {
  log ERROR "Missing summary output: $summary_file"
  exit 1
}
summary_task_count="$(multipass exec "$CONTROLLER_NAME" -- grep -c '^task_id=' "$summary_file")"
[[ "$summary_task_count" == "$ARRAY_TASK_COUNT" ]] || {
  log ERROR "Expected $ARRAY_TASK_COUNT summary records; observed $summary_task_count"
  exit 1
}
multipass exec "$CONTROLLER_NAME" -- cat "$summary_file"
log INFO "Array job $ARRAY_JOB_ID and dependency job $SUMMARY_JOB_ID completed successfully"
