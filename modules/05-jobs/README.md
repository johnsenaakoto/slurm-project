# Module 05: Validate scheduling and jobs

This module submits a short batch job requesting one task on each worker. It
waits for a successful `COMPLETED` state, determines the selected `BatchHost`,
reads the output from that worker, and verifies that both worker hostnames are
present.

Reading from `BatchHost` is intentional: the Multipass guests do not share
their `/home/ubuntu` or `/tmp` filesystems.

Preview the job without submitting it:

```bash
./modules/05-jobs/validate-jobs.sh --dry-run
```

Run the end-to-end scheduling test:

```bash
./modules/05-jobs/validate-jobs.sh
```

The temporary remote output file is removed when the module exits. The full
test transcript remains in the timestamped log under `logs/`.
