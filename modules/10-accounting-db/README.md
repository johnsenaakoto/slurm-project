# Module 10: Slurm accounting database

This module enables persistent Slurm job accounting with `slurmdbd` and
MariaDB, then proves that completed jobs are visible through both `sacct` and
the underlying accounting database.

The module:

1. installs MariaDB and `slurmdbd` on the controller
2. creates the Slurm accounting database and local database user
3. writes `/etc/slurm/slurmdbd.conf`
4. enables accounting settings in `slurm.conf` on the controller and workers
5. registers the lab cluster, account, and user association
6. submits successful, failed, and two-CPU demonstration jobs
7. verifies the jobs with `sacct`
8. queries the MariaDB job table directly

## Configure

Settings live in [`config/cluster.env`](../../config/cluster.env):

```bash
ACCOUNTING_PACKAGES="mariadb-server slurmdbd"
ACCOUNTING_DB_NAME="slurm_acct_db"
ACCOUNTING_DB_USER="slurm"
ACCOUNTING_DB_AUTH_FILE="/etc/slurm/slurmdbd-mysql.auth"
ACCOUNTING_ACCOUNT="lab"
ACCOUNTING_DEMO_USER="ubuntu"
ACCOUNTING_TEST_DIR="/shared/accounting-lab"
ACCOUNTING_JOB_TIMEOUT_SECONDS="180"
```

If `ACCOUNTING_DB_AUTH` is not set in the environment, the module generates a
random local database auth string on the controller and stores it at
`ACCOUNTING_DB_AUTH_FILE` with `0600` permissions.

Module 04 rewrites `slurm.conf` from scratch. If you rerun Module 04 after this
module, rerun Module 10 to restore the accounting settings.

## Run

From the project root:

```bash
./modules/10-accounting-db/configure-accounting-db.sh
```

Preview the planned changes without installing packages, changing services, or
submitting jobs:

```bash
./modules/10-accounting-db/configure-accounting-db.sh --dry-run
```

## What to inspect

From the controller, inspect persistent accounting with:

```bash
sacct -S today -o JobID,JobName,Account,State,ExitCode,Elapsed,AllocCPUS,ReqCPUS,NodeList
sacctmgr show assoc
```

The MariaDB files live under `/var/lib/mysql`, and this lab stores Slurm
accounting records in `/var/lib/mysql/slurm_acct_db`.

To inspect the raw job table directly:

```bash
sudo mysql slurm_acct_db -e "SHOW TABLES;"
sudo mysql slurm_acct_db -e "DESCRIBE \`slurm-lab_job_table\`;"
```

Because the configured cluster name is `slurm-lab`, MariaDB table names contain
a hyphen and must be quoted with backticks:

```bash
sudo mysql slurm_acct_db -e "
SELECT
  id_job,
  job_name,
  account,
  \`partition\`,
  cpus_req,
  nodes_alloc,
  nodelist,
  state,
  exit_code,
  FROM_UNIXTIME(time_submit) AS submitted,
  FROM_UNIXTIME(time_start) AS started,
  FROM_UNIXTIME(time_end) AS ended,
  tres_req,
  tres_alloc
FROM \`slurm-lab_job_table\`
ORDER BY id_job DESC
LIMIT 10;
"
```

`sacct` remains the best human interface. The SQL view is useful for learning
where `slurmdbd` persists raw accounting facts.
