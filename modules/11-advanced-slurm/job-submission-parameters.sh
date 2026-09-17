#!/bin/bash
#SBATCH -t 00:05:00
#SBATCH -n 1
#SBATCH -N 1
#SBATCH --job-name=batch_param_example
#SBATCH -p debug
##SBATCH -A MY_ACCOUNT
#SBATCH --output=/shared/slurm-%j.out

set -euo pipefail

: "${MY_PARAM:?Export MY_PARAM before submitting this job}"
printf 'Job %s received MY_PARAM=%s\n' "$SLURM_JOB_ID" "$MY_PARAM"
