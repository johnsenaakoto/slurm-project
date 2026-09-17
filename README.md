# Three-node Slurm cluster on Multipass

An automated, observable build of a three-node Slurm cluster running in Ubuntu
24.04 VMs on Apple Silicon. The project demonstrates Linux systems
administration, cluster networking, role-based package installation, and
shared MUNGE authentication from a macOS host.

## Architecture

| Node | Role | Service |
| --- | --- | --- |
| `slurm-controller` | Scheduling and cluster management | `slurmctld` |
| `slurm-worker1` | Job execution | `slurmd` |
| `slurm-worker2` | Job execution | `slurmd` |

Multipass provides isolated ARM64 Ubuntu VMs. Each module is configurable,
idempotent where practical, validates its outcome, and writes timestamped
diagnostic logs with actionable failure context.

## Highlights

- Single declarative configuration for node identity, resources, and packages
- Automatic IP discovery and managed hostname resolution
- All-to-all connectivity, OS identity, NTP, and clock-skew validation
- Role-specific Slurm installation with consistent version checks
- Secure MUNGE key distribution without persisting keys on macOS
- Local and cross-node authentication tests
- Structured phases, failure recovery, dry runs, and persistent logs

## Progress

| Module | Outcome | Status |
| --- | --- | --- |
| [`00-reset`](modules/00-reset/README.md) | Permanently remove the configured VMs for a clean rebuild | Complete |
| [`01-create-nodes`](modules/01-create-nodes/README.md) | Provision and verify three Ubuntu VMs | Complete |
| [`02-networking`](modules/02-networking/README.md) | Configure resolution; verify networking, identity, and time | Complete |
| [`03-software-and-munge`](modules/03-software-and-munge/README.md) | Install Slurm software and validate shared authentication | Complete |
| [`04-slurm`](modules/04-slurm/README.md) | Discover resources, configure services, and verify idle workers | Complete |
| [`05-jobs`](modules/05-jobs/README.md) | Run and validate a two-node batch job | Complete |
| [`06-shared-storage`](modules/06-shared-storage/README.md) | Configure shared NFS storage across the controller and workers | Complete |
| [`07-arrays-and-dependencies`](modules/07-arrays-and-dependencies/README.md) | Run a Slurm array job and an `afterok` summary dependency | Complete after accounting setup |
| [`08-resource-constrained-pending`](modules/08-resource-constrained-pending/README.md) | Observe a valid job pending because worker CPUs are fully allocated | Complete |
| [`09-node-drain-recovery`](modules/09-node-drain-recovery/README.md) | Drain, fail, recover, and resume Slurm worker nodes | Complete |
| [`10-accounting-db`](modules/10-accounting-db/README.md) | Enable `slurmdbd` accounting and inspect completed jobs in MariaDB | Complete |
| [`11-advanced-slurm`](modules/11-advanced-slurm/README.md) | Cornell course notes and examples for parameters and dependencies | Basics and job submission studied |

See the [standalone job notes](jobs/README.md) for `hello-slurm.sh` and the
module 11 notes for explanations of each course script.

## Quick start

Requirements: macOS 14+, Multipass, approximately 4 GB RAM, and up to 24 GB
disk capacity.

Verify Multipass and review [`config/cluster.env`](config/cluster.env) before
running the modules:

```bash
multipass version
```

```bash
./modules/01-create-nodes/create-nodes.sh
./modules/02-networking/configure-networking.sh
./modules/03-software-and-munge/install-and-validate.sh
./modules/04-slurm/configure-and-start.sh
./modules/05-jobs/validate-jobs.sh
./modules/06-shared-storage/configure-shared-storage.sh
./modules/10-accounting-db/configure-accounting-db.sh
./modules/07-arrays-and-dependencies/run-arrays-and-dependencies.sh
./modules/08-resource-constrained-pending/run-resource-pending.sh
./modules/09-node-drain-recovery/run-node-drain-recovery.sh
```

Use `--dry-run` to preview a module or `--config /path/to/cluster.env` to use a
different complete configuration.

To preview a clean reset before rebuilding:

```bash
./modules/00-reset/reset-cluster.sh --dry-run
```

The live reset permanently deletes the three configured VMs and requires an
explicit confirmation. See the [reset module](modules/00-reset/README.md).

## Configuration and operations

[`config/cluster.env`](config/cluster.env) is the single source of truth. IP
addresses are discovered at runtime, and secrets such as the MUNGE key are
never stored in configuration.

Runtime logs are written to `logs/` and excluded from version control. The
provisioning modules do not delete existing instances; only the explicitly
invoked reset module does so.

```bash
multipass list
multipass stop slurm-controller slurm-worker1 slurm-worker2
multipass start slurm-controller slurm-worker1 slurm-worker2
```
