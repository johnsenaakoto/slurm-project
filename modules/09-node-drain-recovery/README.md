# Module 09: Node drain, failure, recovery, and resume

This module walks through a scheduler-state operations drill. It shows how an
administrator drains a healthy worker, marks another worker down, verifies the
controller is still healthy, and then returns both workers to service.

The exercise changes only Slurm's view of node state. It does not stop
Multipass instances or kill `slurmd`.

## Configure

Settings live in [`config/cluster.env`](../../config/cluster.env):

```bash
NODE_RECOVERY_TIMEOUT_SECONDS="60"
NODE_DRAIN_REASON="lesson-drain"
NODE_FAILURE_REASON="lesson-failure"
```

The timeout controls how long the module waits for Slurm to reflect each state
change.

## Run

From the project root:

```bash
./modules/09-node-drain-recovery/run-node-drain-recovery.sh
```

Preview the state changes without changing Slurm:

```bash
./modules/09-node-drain-recovery/run-node-drain-recovery.sh --dry-run
```

## Exercise sequence

1. Verify both workers start as `idle`.
2. Try to drain a worker as the normal `ubuntu` user and observe
   `Invalid user id`.
3. Drain `slurm-worker1` with `sudo scontrol update`.
4. Mark `slurm-worker2` as `DOWN`.
5. Confirm `slurmctld` still responds with `scontrol ping`.
6. Resume both workers.
7. Clear stale node reasons and verify both workers are `idle` with reason
   `none`.

## What to inspect

During the module, inspect node state from the controller:

```bash
sinfo -Nel
scontrol show node slurm-worker1
scontrol show node slurm-worker2
```

`DRAIN` means an administrator intentionally removed a node from new
allocations. `DOWN` means Slurm considers the node unavailable. Once a node is
already `idle`, another `State=RESUME` can be rejected as an invalid state
update; at that point, clear the stale reason instead.
