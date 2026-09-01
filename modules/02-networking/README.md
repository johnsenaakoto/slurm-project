# Module 02: Configure and verify networking

This module configures hostname resolution between the Multipass nodes. It
also verifies node-to-node connectivity, Ubuntu identity, and clock
synchronization—the foundations Slurm and MUNGE require.

The script discovers each VM's current IPv4 address, so the addresses do not
need to be hard-coded. It owns only the block between these markers in each
VM's `/etc/hosts` file:

```text
# BEGIN SLURM CLUSTER NODES
# END SLURM CLUSTER NODES
```

Other `/etc/hosts` entries are left unchanged. Re-running the script replaces
its managed block, making it safe to use after VM IP addresses change.

## Configure

Edit the shared [`config/cluster.env`](../../config/cluster.env) if your
instance names differ or if you want to change the expected Ubuntu release,
ping count, or permitted clock skew.

## Run

From the project root:

```bash
./modules/02-networking/configure-networking.sh
```

To use another configuration file:

```bash
./modules/02-networking/configure-networking.sh --config /path/to/cluster.env
```

Preview the discovered addresses and proposed `/etc/hosts` block without
changing the VMs:

```bash
./modules/02-networking/configure-networking.sh --dry-run
```

The module succeeds only when all configured nodes are running and all checks
pass.

## Logs and troubleshooting

Every run writes a timestamped log under `logs/` at the project root. It
records discovered addresses, `/etc/hosts` read-back results, OS identity,
every connectivity path, ping statistics, NTP state, timestamps, and measured
clock skew. On an unexpected failure it also records the exit code, script
line, and failed command. Change `LOG_DIR` in the shared configuration if
needed.
