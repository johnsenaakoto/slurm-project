# Slurm Lab Progress Checkpoint

Saved: September 1, 2026

## Goal

Build a working three-node Slurm learning cluster on a MacBook and run interactive and batch jobs.

## Host environment

- MacBook Air with Apple M1, 8 CPU cores, and 16 GB RAM
- macOS 26.6.2
- Multipass 1.16.3
- Project directory used on Mac: `slurm-project`

## Cluster topology

| Node | Role | IP address | VM resources | Operating system |
|---|---|---:|---|---|
| `slurm-controller` | Slurm controller | `192.168.252.2` | 2 CPUs, 1 GB RAM, 8 GB disk | Ubuntu 24.04.4 LTS ARM64 |
| `slurm-worker1` | Compute worker | `192.168.252.3` | 2 CPUs, 1.5 GB RAM, 8 GB disk | Ubuntu 24.04.4 LTS ARM64 |
| `slurm-worker2` | Compute worker | `192.168.252.4` | 2 CPUs, 1.5 GB RAM, 8 GB disk | Ubuntu 24.04.4 LTS ARM64 |

## Completed and verified

- Created and started all three Multipass VMs.
- Added the same hostname mappings to `/etc/hosts` on every VM.
- Verified hostname resolution in every required direction with `getent hosts`.
- Verified controller-to-worker and worker-to-controller connectivity with `ping`; all tests had 0% packet loss.
- Verified matching `ubuntu` user identity and synchronized clocks across the nodes.
- Installed `munge`, `slurmctld`, and `slurm-client` on the controller.
- Installed `munge`, `slurmd`, and `slurm-client` on both workers.
- Distributed the controller's MUNGE key to both workers.
- Verified that `/etc/munge/munge.key` has the same SHA-256 hash on all three nodes.

## Important observation

Running `srun --version` before creating `slurm.conf` produced DNS SRV/config-source errors. This was expected: `srun` tried Slurm's configless discovery because no configuration source existed yet. It did not indicate a broken package installation or broken `/etc/hosts` networking.

## Resume point

Before writing `slurm.conf`, perform the final MUNGE validation if it was not completed:

1. Confirm `munge` is active on all three nodes.
2. Confirm local `munge -n | unmunge` returns `STATUS: Success (0)` on every node.
3. Confirm a credential encoded on `slurm-controller` can be decoded on both workers.

Then finish the lab in this order.

### 1. Create the Slurm configuration

- Create one shared `/etc/slurm/slurm.conf`.
- Define `slurm-controller` as `SlurmctldHost`.
- Define `slurm-worker1` and `slurm-worker2` with their CPUs and usable memory.
- Create a default `debug` partition containing both workers.
- Create and permission the controller and worker spool/state directories.
- Distribute the identical configuration to all three nodes.

### 2. Start the Slurm daemons

- Start and enable `slurmctld` on the controller.
- Start and enable `slurmd` on both workers.
- Inspect service logs if startup fails.
- Use `sinfo`, `scontrol show nodes`, and `scontrol update` to diagnose nodes that are `DOWN`, `UNKNOWN`, or otherwise unavailable.

### 3. Run actual jobs

- Use `srun` for an interactive test across the workers.
- Write and submit a batch script with `sbatch`.
- Inspect jobs with `squeue`.
- Inspect cluster and node state with `sinfo` and `scontrol`.
- Verify output files and which worker executed each task.

## Optional later labs

These are not required to finish the initial installation:

- `slurmdbd` and persistent job accounting
- Shared storage
- GPU Generic Resources (GRES)
- Job arrays, reservations, QoS, fair-share, and backfill experiments
- Node failure and recovery exercises
- Ansible or cloud-init automation of the manual build
