# Module 01: Create the nodes

This module creates one controller and two worker VMs using Multipass. It is
safe to run more than once: a VM that already exists is reported and skipped.

## Configure

Edit the shared [`config/cluster.env`](../../config/cluster.env) to change the
Ubuntu image, node names, CPU count, memory, or disk allocation.

Values use formats accepted by Multipass, such as `1G`, `1500M`, and `8G`.
Node names must be valid Multipass instance names.

## Run

From the project root:

```bash
./modules/01-create-nodes/create-nodes.sh
```

To use a different configuration file:

```bash
./modules/01-create-nodes/create-nodes.sh --config /path/to/cluster.env
```

Preview the commands without changing anything:

```bash
./modules/01-create-nodes/create-nodes.sh --dry-run
```

At the end, the script prints `multipass list` and verifies the hostname and
Ubuntu release on each running node.

## Logs and troubleshooting

Every run writes a timestamped log under `logs/` at the project root. The log
records phases, resource settings, commands, node state, guest identity, and
the exact line and command responsible for an unexpected failure. Change
`LOG_DIR` in the shared configuration to store logs elsewhere.
