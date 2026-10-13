# Authoring guide

How lessons, exercises and lab scenarios are written in this repository. Read
it before contributing a module or a scenario. The short version: **every
command a student is told to run has been run, and CI runs it again.**

## Course layout

```text
courses/mysql-production-dba/
├── README.md                 course overview, module map, progress checklist
└── NN-slug/
    ├── README.md             the lesson
    ├── exercise.md           the hands-on exercise(s), validated by ./lab check
    └── quiz.md               self-assessment, answers in collapsed <details>
```

Module directories:

| # | Directory | Scenario(s) |
|---|---|---|
| 1 | `01-architecture` | `01-*` |
| 2 | `02-install-config-access` | `02-*` |
| 3 | `03-innodb-transactions-locking` | `03-*` |
| 4 | `04-explain-indexing` | `04-*` |
| 5 | `05-performance-diagnostics` | `05-*` |
| 6 | `06-backup-restore` | `06-*` |
| 7 | `07-replication-ha` | `07-*` |
| 8 | `08-monitoring-observability` | `08-*` |
| 9 | `09-incident-response` | `09-*` |
| 10 | `10-final-challenge` | `10-*` |

## Lesson template (`README.md`)

```markdown
# Module N — Title

`time: ~60 min` · `lab: ./lab scenario setup NN-name` · `level: fundamentals`

One paragraph: why a production DBA cares about this.

## Learning objectives
## Prerequisites
## <Concept sections, each ending in something to run>
## Common mistakes and troubleshooting
## Further reading
## Next
```

Rules:

- **Name the mechanism.** "InnoDB takes a next-key lock on every index record
  the scan touches", not "MySQL locks rows".
- **Cite the source.** Behavioural claims link to the MySQL 8.4 Reference
  Manual (`https://dev.mysql.com/doc/refman/8.4/en/...`) or the tool's own
  documentation. No blog posts as the authority.
- **Show real output.** Output samples are copied from the lab, trimmed with
  `...` where long. The dataset is deterministic, so row counts and EXPLAIN
  plans match what students see. Timing numbers will differ — say so.
- **No invented experience.** Do not write "in production we once…". Where a
  first-hand incident story from the course author would help, leave an HTML
  comment for the founder review:
  `<!-- founder-review: a real story about X would help here -->`.
- **British English**, the MoiToi.TECH voice: concise, specific, no filler,
  status stated honestly. Write MoiToi.TECH, not MoiToi Tech.
- **Mobile-readable.** Short paragraphs; tables of at most four columns; code
  lines under ~90 characters where possible.

## Executable code blocks

`labs/tests/doctest.py` runs every fenced block whose info string contains
`test`. CI runs it on a freshly reset lab, file by file in module order.

| Info string | Runs |
|---|---|
| `sql test` | on the primary as root; must succeed |
| `sql test replica` | on the replica |
| `sql test expect-error` | must fail (permission demos, deliberate errors) |
| `bash test` | `bash -euo pipefail` from `labs/`; `./lab ...` works |
| `bash test expect-error` | must fail |

Untagged blocks are displayed but not run: output samples, config excerpts,
interactive or destructive commands. Tag everything a student should run
unless it cannot run unattended. A lesson file must leave the lab as it found
it (end with `./lab scenario reset ...` in a `bash test` block if it set one
up). Students run commands from the `labs/` directory.

## Scenarios (`labs/scenarios/NN-name/`)

| File | Purpose |
|---|---|
| `setup.sh` | Injects the fault. First line after the shebang: `# summary: one line`. |
| `check.sh` | Validates the student's fix. Prints PASS/FAIL lines and hints; exit 0 only when solved. Must **fail** right after `setup.sh`. |
| `reset.sh` | Restores the baseline whether or not the scenario was solved. Idempotent. |
| `solve.sh` | Reference fix. Used by CI; students are told it exists and asked to try first. |
| `README.md` | Optional: operator notes. The student-facing text lives in the module's `exercise.md`. |

Every script starts with:

```bash
#!/usr/bin/env bash
# summary: ...            (setup.sh only)
. "$LAB_DIR/scripts/lib.sh"
```

and uses the helpers from `labs/scripts/lib.sh`: `sql`, `sqlv`, `dc`,
`wait_replica_caught_up`, `pass`, `fail`, `hint`, `expect`, `check_result`.
Scripts are run by `./lab scenario <action> <name>`, which exports `LAB_DIR`.

Requirements, enforced by `labs/tests/scenario-test.sh`:

1. Deterministic: the same setup produces the same fault every time.
2. `check.sh` fails after setup and passes after `solve.sh`.
3. `reset.sh` restores the dataset fingerprint on both servers and leaves
   replication running, from either the solved or the unsolved state.
4. Background load generators started by `setup.sh` (e.g. a blocking
   transaction) run inside a container, are tracked (pid file or container
   name), and are stopped by `reset.sh`.
5. Exercise artefacts that are not part of the shop dataset go in a separate
   schema named `lab` on the primary, which `reset.sh` drops.
6. Never touch `mysql.*` grants of the lab's built-in accounts (`root`,
   `repl`, `app`, `exporter`) without restoring them in `reset.sh`.

Test a scenario with the lab running:

```bash
labs/tests/scenario-test.sh 04-missing-index
```

## Running several labs side by side

`./lab` reads `DBRE_PROJECT` and the `DBRE_*_PORT` variables, so independent
copies can run on one machine:

```bash
export DBRE_PROJECT=dbre-b DBRE_PRIMARY_PORT=23306 DBRE_REPLICA_PORT=23307 \
       DBRE_PROMETHEUS_PORT=29090 DBRE_GRAFANA_PORT=23000
./lab up
```
