# Module 11: Advanced Slurm course examples

Notes for the Cornell [Advanced Slurm: Job Submission](https://cvw.cac.cornell.edu/slurm/job-submission/index)
exercises. These scripts assume this lab's `debug` partition and writable
`/shared` NFS directory on the controller and both workers (module 06).
Run submission commands on the controller, where `sbatch` is installed.

## Copy and submit

From the repository root on macOS:

```bash
multipass transfer --recursive modules/11-advanced-slurm slurm-controller:/shared/
multipass shell slurm-controller
cd /shared/11-advanced-slurm
```

If that directory already exists, update its files individually with
`multipass transfer modules/11-advanced-slurm/*.sh slurm-controller:/shared/11-advanced-slurm/`.
The examples below run inside the controller VM. Use `sbatch` for batch
scripts; use `bash` for the submission wrapper.

## Shared directives

All five batch examples request one node (`-N 1`), one task (`-n 1`), and a
five-minute wall-clock limit (`-t 00:05:00`) in `debug` (`-p debug`). These are
small shell workloads; reserving extra tasks would not run extra copies.
`%j` in an output filename expands to the job ID. Output files live on NFS,
so the report can read results regardless of which worker ran each job.

`##SBATCH -A MY_ACCOUNT` is an inactive comment. On a cluster requiring an
account, supply `sbatch --account=YOUR_ACCOUNT ...`. Optional email can be
enabled with `--mail-type=END --mail-user=YOUR_ADDRESS`; delivery requires
cluster mail configuration.

Slurm reads `#SBATCH` lines before the shell executes; shell variables in
those lines do not expand. Command-line options override script directives.
`set -euo pipefail` follows the directives so shell command failures are
reported as job failures rather than hidden by later successful commands.

## Each script

| Script | Purpose | Output |
| --- | --- | --- |
| `sleep.sh` | Prints start/end timestamps around a 120-second sleep; gives time to inspect a running job. | `/shared/slurm-JOB_ID.out` |
| `done.sh` | Prints its start timestamp and sleeps 60 seconds; its dependency is supplied at submission, not embedded in the script. | `/shared/slurm-JOB_ID.out` |
| `job-submission-parameters.sh` | Requires a nonempty exported `MY_PARAM` and prints its value. Replaces the original missing `/shared/my_program.sh` placeholder with a runnable example. Quoting preserves spaces and wildcard characters. | `/shared/slurm-JOB_ID.out` |
| `mainJobScript.sh` | Requires one positional argument, sleeps 10 seconds, then prints that parameter and its job ID. | `/shared/mainJobScript_JOB_ID.out` and `.err` |
| `reportScript.sh` | Requires a colon-separated list of numeric IDs and extracts the parameter line from each corresponding main-job output, in submission order. Missing files or missing matches fail the report. | `/shared/reportScript_JOB_ID.out` and `.err` |
| `series_dependency.sh` | Submission wrapper, not a batch job. Submits four independent main jobs with arguments 0-3, then a report depending on successful completion of all four. | Submission IDs on the terminal; batch outputs above. |

## Dependency exercise

```bash
main_id=$(sbatch --parsable --chdir=/shared sleep.sh)
main_id=${main_id%%;*}
sbatch --chdir=/shared --kill-on-invalid-dep=yes --dependency="afterok:$main_id" done.sh
squeue -o '%.18i %.20j %.10T %.30R'
```

`afterok` releases the dependent job only after the main job exits zero.
`afterany` waits for termination regardless of success, and `afternotok`
waits for unsuccessful completion. A satisfied dependency makes a job
eligible; it may still wait for resources. `--kill-on-invalid-dep=yes`
cancels a dependent job if its dependency can never be satisfied.

## Parameters and reporting

```bash
export MY_PARAM='a value with spaces'
sbatch --export=ALL --chdir=/shared job-submission-parameters.sh
sbatch --chdir=/shared mainJobScript.sh 'example parameter'
bash series_dependency.sh
```

The wrapper resolves its batch scripts relative to itself, so it can be run
from another directory. `--parsable` avoids extracting IDs from human-readable
messages; an optional `;cluster` suffix is removed. Submission failures stop
the wrapper. Already accepted jobs remain queued/running if a later
submission fails; inspect the printed IDs and use `scancel JOB_ID` as needed.

Despite its name, `series_dependency.sh` does not chain the four main jobs.
They may run concurrently. Only the final report has an `afterok` dependency
on every main job. It passes the same colon-separated IDs as a positional
argument so the report knows which files to read.

Inspect jobs and completed results:

```bash
squeue
sacct -X --format=JobID,JobName,State,ExitCode
cat /shared/reportScript_JOB_ID.out
cat /shared/reportScript_JOB_ID.err
```

Replace `JOB_ID` with the report ID printed by the wrapper. Accounting
requires module 10; `scontrol show job JOB_ID` is useful for recent jobs.

## Review notes

The review replaced backticks and unquoted substitutions, removed dependence
on parsing localized `sbatch` messages, validated report IDs and arguments,
and made failed commands propagate nonzero exit status. Email settings are
now opt-in. Paths and resource requests remain specific to this lab.

Validation on 2026-09-17: all repository shell scripts passed `bash -n`.
Live jobs 107-113 completed successfully: four main jobs, their report,
the exported parameter example, and the two-node standalone job. The report
contained all four expected values; spaces and a literal `*` survived export.
Job 114 completed its 120-second sleep, and dependent job 115 started one
second after it finished and completed successfully. Negative checks confirmed that missing arguments
and missing report inputs fail (jobs 116 and 118), and an impossible `afterok`
dependency is cancelled (job 117). Mocked submission checks confirmed that
failed `sbatch` calls and malformed IDs stop the wrapper. ShellCheck was not
installed, so style review was manual.

References: [Cornell course](https://cvw.cac.cornell.edu/slurm/job-submission/index)
and the official [sbatch reference](https://slurm.schedmd.com/sbatch.html)
for directives, exports, parsable IDs, and dependency behavior.
