#!/bin/bash
#SBATCH -t 00:05:00
#SBATCH -n 1
#SBATCH -N 1
#SBATCH --job-name=reportScript
#SBATCH --output=/shared/reportScript_%j.out
#SBATCH --error=/shared/reportScript_%j.err
#SBATCH -p debug
##SBATCH -A MY_ACCOUNT

set -euo pipefail

if (( $# != 1 )) || [[ ! $1 =~ ^[0-9]+(:[0-9]+)*$ ]]; then
  echo "Usage: sbatch reportScript.sh JOB_ID[:JOB_ID...]" >&2
  exit 1
fi

IFS=: read -r -a JOB_IDS <<< "$1"
for JOB_ID in "${JOB_IDS[@]}"; do
  grep -F 'parameter value' "/shared/mainJobScript_${JOB_ID}.out"
done
