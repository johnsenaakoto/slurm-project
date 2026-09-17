#!/bin/bash
#SBATCH -t 00:05:00
#SBATCH -n 1
#SBATCH -N 1
#SBATCH --job-name=mainJob
#SBATCH -p debug
##SBATCH -A MY_ACCOUNT
#SBATCH --output=/shared/slurm-%j.out

set -euo pipefail

echo "Main job started at: $(date)"
sleep 120
echo "Main job finished at: $(date)"
