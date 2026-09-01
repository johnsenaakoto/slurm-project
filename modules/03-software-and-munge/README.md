# Module 03: Install software and configure MUNGE

This module installs the role-specific Slurm and MUNGE packages, then creates
a shared authentication domain using the controller's MUNGE key.

| Node role | Default packages |
| --- | --- |
| Controller | `munge slurmctld slurm-client` |
| Worker | `munge slurmd slurm-client` |

Slurm daemons are deliberately stopped after installation. They cannot start
correctly until Module 04 supplies `slurm.conf`; an `srun --version` command
may also attempt configuration discovery and fail at this stage. This module
uses daemon-specific `-V` commands and package metadata for version checks.

## Security behavior

The controller's `/etc/munge/munge.key` becomes the authoritative cluster key.
It is streamed directly to each worker and installed with owner `munge`, group
`munge`, and mode `0400`. No MUNGE key or test credential is written to the
Mac filesystem, and no temporary credential files are left in the VMs.
If a run is interrupted during key maintenance, failure cleanup removes the
known staged-key path and attempts to restart MUNGE on every node.

Re-running the module is safe: APT installation is idempotent, worker keys are
replaced with the controller key, and MUNGE is restarted and revalidated.

## Configure

Edit the shared [`config/cluster.env`](../../config/cluster.env) to change
instance names, package lists, APT behavior, or the log directory. Package
names may contain letters, numbers, periods, plus signs, and hyphens only.

## Run

Preview the intended operations:

```bash
./modules/03-software-and-munge/install-and-validate.sh --dry-run
```

Install, configure, and validate:

```bash
./modules/03-software-and-munge/install-and-validate.sh
```

Use another configuration file if needed:

```bash
./modules/03-software-and-munge/install-and-validate.sh --config /path/to/cluster.env
```

## Validation and logs

The script verifies:

- expected packages and versions on every node;
- matching `slurm-client` versions across the cluster;
- matching MUNGE key SHA-256 fingerprints;
- key ownership and mode;
- active and enabled MUNGE services;
- a local MUNGE encode/decode round trip on every node; and
- controller-issued credentials decoded directly on both workers.

Every run writes a timestamped diagnostic log under `logs/`. The key itself
and encoded credentials are never printed to the terminal or log.
