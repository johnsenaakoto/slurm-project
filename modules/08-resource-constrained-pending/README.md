# Module 08: Resource-constrained pending jobs

This module demonstrates a common Slurm queue state: a job is valid and
eligible to run, but remains pending because all matching worker resources are
already allocated.

The module:

1. verifies both workers are idle
2. reads the configured CPU count for each worker
3. submits a blocker job that fills every schedulable CPU on both workers
4. submits a waiter job that needs one CPU on one worker
5. confirms the waiter is pending because capacity is unavailable
6. cancels the blocker and verifies the waiter runs to completion

## Configure

Settings live in [`config/cluster.env`](../../config/cluster.env):

```bash
RESOURCE_PENDING_TIMEOUT_SECONDS="180"
RESOURCE_PENDING_BLOCKER_SLEEP_SECONDS="180"
```

The blocker sleep is intentionally long enough to inspect the queue. The module
cancels the blocker after it observes the pending waiter.

## Run

From the project root:

```bash
./modules/08-resource-constrained-pending/run-resource-pending.sh
```

Preview the generated batch scripts without submitting jobs:

```bash
./modules/08-resource-constrained-pending/run-resource-pending.sh --dry-run
```

## What to inspect

While the module is running, inspect the queue from the controller:

```bash
watch -n 1 'squeue -o "%.18i %.18j %.8T %.12M %.20R %.19S"'
```

The waiter job should stay `PENDING` while the blocker is running. Depending on
the scheduler cycle and backfill planning, the wait reason can appear as:

| Reason | Meaning |
| --- | --- |
| `Resources` | Slurm has no currently available CPU/node allocation for the job |
| `None` with no allocation | The job is eligible and unallocated, but Slurm has not surfaced a specific reason in the queue display |
| `InvalidAccount` briefly | A transient queue display during this lab's simple accounting setup |

In all successful cases, the waiter has no allocation while the blocker owns
the worker CPUs. After cancellation, the waiter should immediately move to
`RUNNING` and then `COMPLETED`.

Useful follow-up commands:

```bash
scontrol show job <job-id>
sinfo -N -o "%N %T %C"
squeue --start -j <job-id>
```
