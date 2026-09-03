# Module 00: Reset the cluster

This destructive maintenance module permanently deletes and immediately
purges only the controller and worker instances named in `cluster.env`. It
does not use Multipass's broad `--all` option, and it preserves repository
files and host-side logs.

Always preview the exact targets first:

```bash
./modules/00-reset/reset-cluster.sh --dry-run
```

An interactive reset requires typing `delete slurm cluster` exactly:

```bash
./modules/00-reset/reset-cluster.sh
```

For intentional non-interactive use:

```bash
./modules/00-reset/reset-cluster.sh --force
```

Afterward, run Modules 01 through 05 to rebuild and validate the cluster.
Existing instances that are already absent are safely skipped.
