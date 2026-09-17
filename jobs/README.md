# Standalone batch jobs

## `hello-slurm.sh`

Submit this script on the controller with `sbatch hello-slurm.sh`. It requests
two nodes in `debug`, with one task on each node, for at most two minutes.
The batch shell itself runs once on the batch host; `srun` launches the two
tasks, each printing its rank (`SLURM_PROCID`) and hostname, then sleeping
30 seconds. Start/end timestamps and `SLURM_JOB_NODELIST` describe the
allocation. A failed `srun` stops the script with a nonzero exit status.

Output goes to `/home/ubuntu/slurm-JOB_ID.out` on the batch host. That path is
not shared between this lab's VMs: locate the host with
`scontrol show job JOB_ID` and read the file there, or override the output
with `sbatch --output=/shared/hello-%j.out hello-slurm.sh` after module 06.
The submission working directory must exist on the workers; use
`--chdir=/home/ubuntu` if submitting from a controller-only directory.

The automated [module 05](../modules/05-jobs/README.md) scheduling test
generates and checks its own batch job; this file is a standalone example.
