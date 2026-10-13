# Curriculum

How the DBRE Academy's first course is put together: who it serves, what a
graduate can demonstrably do, how that is assessed, and why the modules are
what they are. The benchmark behind these choices is in
[research.md](research.md).

## Design principles

1. **Outcomes are things you can do, checked by a machine.** Every module
   ends in a scenario on a real server; `./lab check` decides whether it is
   solved. Reading is not completion.
2. **Mechanism before procedure.** A runbook step is taught together with
   the internal mechanism that makes it right — the redo log before crash
   recovery, the read view before the long-transaction problem.
3. **The manual is the authority.** Behavioural claims cite the MySQL 8.4
   Reference Manual or the tool's own documentation. Where the lab behaves
   differently from the manual, the course says so and shows the output.
4. **Deterministic labs.** The dataset is generated from row numbers, so
   counts, checksums and query plans are the same on every machine, and CI
   can verify every exercise on every change.
5. **Production habits, not exam topics.** No vendor certification is
   targeted (see [research.md §4.5](research.md#45-certification-stance)).

## Audience and entry level

| Audience | Typical starting point | What they get most from |
|---|---|---|
| Linux system administrators | Comfortable on a shell, little SQL | Modules 1, 2, 6, 9 |
| Junior DBAs | Some SQL and administration | All modules; 7–10 in particular |
| Backend developers | Strong SQL, little operations | Modules 3, 4, 5 |
| DevOps engineers and SREs | On-call experience, monitoring | Modules 7, 8, 9, 10 |

Prerequisites for everyone: a terminal, basic SQL, Docker on a laptop.

## Outcomes per module

| # | Module | A graduate can… | Assessed by |
|---|---|---|---|
| 1 | Architecture and internals | map a connection to its OS thread, find which binary log holds a change, measure a table's buffer pool footprint, move a table between tablespaces | `01-architecture-tour` |
| 2 | Installation, configuration, secure access | find where a variable's value came from, undo runtime and persisted drift, build a least-privilege role-based account that requires TLS and locks after failed logins | `02-config-drift`, `02-least-privilege` |
| 3 | InnoDB transactions, MVCC, locking | find the root blocker in a lock-wait chain and in a metadata-lock queue, and clear it without collateral damage | `03-lock-contention`, `03-metadata-lock` |
| 4 | Execution plans and indexing | read a plan and design the composite index that removes a scan and a filesort — not a single-column index that merely looks better | `04-missing-index` |
| 5 | Performance diagnostics | rank a live workload by total time with statement digests, identify a non-sargable predicate, fix it on the database side and prove the change in rows examined | `05-slow-query` |
| 6 | Backup, restore, integrity | restore a logical backup and replay binary logs while skipping exactly one bad transaction, then prove the result by fingerprint | `06-pitr` |
| 7 | Replication and HA | find why a replica lags and remove the cause; repair a broken replica so it is consistent, has no new errant GTIDs and is read-only | `07-replication-lag`, `07-broken-replication` |
| 8 | Monitoring and observability | write a symptom-based, actionable Prometheus alert that fires on saturation on the primary only | `08-saturation-alert` |
| 9 | Incident response | get into a server at its connection limit and stop the source; recover a server that will not start because of a persisted setting, keeping the legitimate ones | `09-too-many-connections`, `09-wont-start` |
| 10 | Final challenge | triage three simultaneous faults by user impact, mitigate without restarts, repair the replica correctly, and write a blameless review | `10-final-incident` + self-assessed rubric |

Each module also has a self-assessment quiz (module 10: a rubric) with
answers collapsed below each question.

## Time budget

| Part | Time |
|---|---|
| Modules 1–9 | about 12 hours |
| Module 10 (final challenge and review) | 2–3 hours |

The original target was 8–12 hours. The modules came out longer because
each exercise is a full diagnose-fix-verify loop on a real server. Learners
with operations experience will move faster through modules 1, 2 and 8.

## Skills coverage

Core DBRE skills from the benchmark ([research.md §3](research.md#3-skills-matrix))
and where this course covers them:

| Skill | Covered in | Depth |
|---|---|---|
| Server architecture, storage engine internals | 1, 3 | Working |
| Configuration management, persisted variables | 2, 9 | Working |
| Access control, TLS, roles | 2 | Working |
| Transactions, isolation, locking, deadlocks | 3 | Working |
| Query plans, indexing, statistics | 4, 5 | Working |
| Workload analysis, slow queries | 5 | Working |
| Logical backup, point-in-time recovery, restore testing | 6 | Working |
| Physical backup (XtraBackup, CLONE) | 6 | Awareness |
| Async replication, GTIDs, lag, errant transactions | 7 | Working |
| Failover, switchover, split brain | 7 | Awareness |
| Metrics, alerting, dashboards | 8 | Working |
| Incident handling, post-incident review | 9, 10 | Working |
| Group Replication / InnoDB Cluster, online schema change, proxies, upgrades | — | Deferred to the advanced course |

*Working*: practised in a lab and checked. *Awareness*: explained and cited,
not practised.

## Lab environment

One MySQL 8.4 primary and one GTID replica in Docker, optionally with
mysqld_exporter, Prometheus and Grafana; the synthetic `shop` dataset
(200 000 orders). Details: [labs/README.md](../labs/README.md).

## Quality assurance

| Check | What it proves | Where |
|---|---|---|
| Scenario tests | Each fault is detected by its check; the reference fix passes it; reset restores the dataset fingerprint and replication, from both the solved and unsolved state | `labs/tests/scenario-test.sh` |
| Lesson doctest | Every command a lesson tells you to run succeeds (or fails where it should), in module order on a fresh lab | `labs/tests/doctest.py` |
| Manual links | Every cited `dev.mysql.com` page exists | `labs/tests/check-manual-links.py` |
| Full run | All of the above from a clean start to a clean teardown, on amd64 and arm64 | `.github/workflows/lab.yml` |
