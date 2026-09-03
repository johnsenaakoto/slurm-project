# Module 04: Configure and start Slurm

This module discovers the current Multipass IPv4 addresses and each worker's
resources, generates one `slurm.conf`, and installs the identical configuration
on every node. It reserves a configurable amount of detected memory for the
guest operating system.

It also creates Slurm's state, spool, and log paths with role-appropriate
ownership; validates configuration parsing; enables and restarts `slurmctld`
and `slurmd`; and waits until both workers register as `IDLE`.

Preview the generated configuration without changing the guests:

```bash
./modules/04-slurm/configure-and-start.sh --dry-run
```

Configure and start the cluster:

```bash
./modules/04-slurm/configure-and-start.sh
```

Every run writes a timestamped diagnostic log under `logs/`. Re-running the
module refreshes the generated configuration and replaces the running daemon
processes. Do not run it while jobs are expected to remain live.
