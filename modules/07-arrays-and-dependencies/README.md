# Module 07: Job arrays and dependencies

This module demonstrates a simple Slurm fan-out/fan-in workflow:

1. submit one array job with multiple indexed tasks
2. write one output file per array task into shared storage
3. submit a summary job with an `afterok` dependency on the array job
4. validate that the summary job runs only after the array succeeds

It assumes Module 06 has already configured shared NFS storage.

## Configure

Settings live in [`config/cluster.env`](../../config/cluster.env):

```bash
SHARED_STORAGE_PATH="/shared"
ARRAY_DEMO_DIR="/shared/arrays-demo"
ARRAY_TASK_COUNT="5"
ARRAY_JOB_TIMEOUT_SECONDS="180"
```

The task count is intentionally small so the scheduling behavior is easy to
watch with `squeue`.

## Run

From the project root:

```bash
./modules/07-arrays-and-dependencies/run-arrays-and-dependencies.sh
```

Preview the generated batch scripts without submitting jobs:

```bash
./modules/07-arrays-and-dependencies/run-arrays-and-dependencies.sh --dry-run
```

## What to inspect

While the module is running, inspect the queue from the controller:

```bash
squeue
```

Array tasks appear with IDs such as `12_0`, `12_1`, and `12_2`. The summary
job should remain pending with reason `Dependency` until the array job
completes successfully.

After completion, inspect:

```bash
cat /shared/arrays-demo/logs/array-*_*.out
cat /shared/arrays-demo/logs/summary-*.out
cat /shared/arrays-demo/outputs/summary.txt
```

If a job is pending with `InvalidAccount`, Slurm accounting enforcement is
enabled before account associations have been configured. That belongs to the
later accounting lab.
