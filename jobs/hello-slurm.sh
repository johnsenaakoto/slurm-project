#!/bin/bash

#SBATCH --job-name=hello-cluster
#SBATCH --partition=debug
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --time=00:02:00
#SBATCH --output=/home/ubuntu/slurm-%j.out

echo "Job $SLURM_JOB_ID started at $(date)"
echo "Allocated nodes: $SLURM_JOB_NODELIST"

srun bash -lc '
  echo "task=$SLURM_PROCID node=$(hostname)"
  sleep 30
'

echo "Job $SLURM_JOB_ID finished at $(date)"
