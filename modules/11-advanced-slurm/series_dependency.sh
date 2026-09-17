#!/bin/bash
set -euo pipefail

SERIES_COUNT=4
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SERIES_BATCH_SCRIPT="$SCRIPT_DIR/mainJobScript.sh"
SERIES_AFTER_SCRIPT="$SCRIPT_DIR/reportScript.sh"
JOBLIST=

for (( i=0; i < SERIES_COUNT; i++ )); do
  echo "Running sbatch ${SERIES_BATCH_SCRIPT} $i"
  NEXTJOB=$(sbatch --parsable --chdir=/shared "$SERIES_BATCH_SCRIPT" "$i")
  # Federated submissions may return job_id;cluster_name.
  NEXTJOB=${NEXTJOB%%;*}
  if [[ ! $NEXTJOB =~ ^[0-9]+$ ]]; then
    echo "Unexpected sbatch job ID: $NEXTJOB" >&2
    exit 1
  fi
  JOBLIST=${JOBLIST:+$JOBLIST:}${NEXTJOB}
done

# Submit a final job to generate a report if the others are successful
echo "Running sbatch --dependency=afterok:${JOBLIST} ${SERIES_AFTER_SCRIPT} ${JOBLIST}"
sbatch --parsable --chdir=/shared --kill-on-invalid-dep=yes \
  "--dependency=afterok:${JOBLIST}" "$SERIES_AFTER_SCRIPT" "$JOBLIST"
