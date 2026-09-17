#!/bin/bash
#SBATCH -t 00:05:00
#SBATCH -n 1
#SBATCH -N 1
#SBATCH --job-name=mainJobScript
#SBATCH --output=/shared/mainJobScript_%j.out
#SBATCH --error=/shared/mainJobScript_%j.err
#SBATCH -p debug
##SBATCH -A MY_ACCOUNT

set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: sbatch mainJobScript.sh PARAMETER" >&2
  exit 1
fi

sleep 10
echo "The parameter value from job $SLURM_JOB_ID is $1"
