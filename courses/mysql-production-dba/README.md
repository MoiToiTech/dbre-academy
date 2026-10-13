# MySQL Production DBA Fundamentals

`MySQL 8.4 LTS` · `10 modules` · `about 13–15 hours` · `free, CC BY 4.0`

A hands-on course in running MySQL in production: how the server works,
how to configure and secure it, how InnoDB locks and recovers, how to read a
query plan, find a slow query, restore to a point in time, keep replicas
correct, monitor the right signals and handle an incident. Each module ends
in a lab exercise in which you fix a real fault on a real server, and
`./lab check` tells you whether you fixed it.

## Who it is for

- **Linux system administrators** who have inherited a MySQL server.
- **Junior DBAs** who want the production habits, not only the SQL.
- **Backend developers** who want to know why their query is slow and what
  the database is doing about their transaction.
- **DevOps engineers and SREs** who are on call for a database they did not
  design.

You need a shell, basic SQL (`SELECT`, `JOIN`, `UPDATE`) and Docker on a
laptop. No prior DBA experience is assumed.

## Before you start

```bash
git clone https://github.com/MoiToiTech/dbre-academy.git
cd dbre-academy/labs
./lab doctor     # checks Docker, memory and ports
./lab up         # first run: ~2 minutes; later: ~20 seconds
./lab status
```

Every command in the course runs from the `labs/` directory. The
[labs README](../../labs/README.md) covers requirements, ports and
troubleshooting.

## Modules

| # | Module | Time | Lab exercise |
|---|---|---|---|
| 1 | [Database architecture and MySQL internals](01-architecture/README.md) | 60 min | `01-architecture-tour` |
| 2 | [Installation, configuration and secure access](02-install-config-access/README.md) | 70 min | `02-config-drift`, `02-least-privilege` |
| 3 | [InnoDB transactions, MVCC and locking](03-innodb-transactions-locking/README.md) | 75 min | `03-lock-contention`, `03-metadata-lock` |
| 4 | [Query execution plans and indexing](04-explain-indexing/README.md) | 80 min | `04-missing-index` |
| 5 | [Performance diagnostics and slow queries](05-performance-diagnostics/README.md) | 75 min | `05-slow-query` |
| 6 | [Backup, restore and data integrity](06-backup-restore/README.md) | 90 min | `06-pitr` |
| 7 | [Replication and high availability fundamentals](07-replication-ha/README.md) | 90 min | `07-replication-lag`, `07-broken-replication` |
| 8 | [Monitoring and observability](08-monitoring-observability/README.md) | 90 min | `08-saturation-alert` |
| 9 | [Incident response and troubleshooting](09-incident-response/README.md) | 90 min | `09-too-many-connections`, `09-wont-start` |
| 10 | [Final challenge: a production incident](10-final-challenge/README.md) | 2–3 h | `10-final-incident` |

Times are for reading, running the examples and doing the exercise. The
modules build on each other; take them in order the first time.

## How each module works

1. **Lesson** (`README.md`): concepts, each followed by commands you run
   against the lab. Output samples are copied from the lab; the dataset is
   deterministic, so row counts and plans match what you see. Timings differ.
2. **Exercise** (`exercise.md`): a scenario injects a fault. You diagnose
   and fix it, then validate:

   ```bash
   ./lab scenario setup 04-missing-index
   # ... investigate and fix ...
   ./lab check 04-missing-index        # exit code 0 = solved
   ./lab scenario reset 04-missing-index
   ```

   Hints are collapsed. A reference fix exists
   (`./lab scenario solve <name>`) — use it only after a real attempt.
3. **Self-assessment** (`quiz.md`; module 10 has `rubric.md`): questions
   with answers collapsed underneath.

## Track your progress

Copy this list into your own notes, or fork the repository and tick it in
place. A box is ticked when `./lab check` passes, not when you have read the
page.

When a check passes, the lab also prints a LinkedIn share link for that
exercise. The page it opens names the exercise, never the fix, and says the
result is self-reported. It is not offered after `./lab scenario solve`: the
reference fix is for learning, not for sharing.

- [ ] 1 — `./lab check 01-architecture-tour`
- [ ] 2 — `./lab check 02-config-drift` and `./lab check 02-least-privilege`
- [ ] 3 — `./lab check 03-lock-contention` and `./lab check 03-metadata-lock`
- [ ] 4 — `./lab check 04-missing-index`
- [ ] 5 — `./lab check 05-slow-query`
- [ ] 6 — `./lab check 06-pitr`
- [ ] 7 — `./lab check 07-replication-lag` and `./lab check 07-broken-replication`
- [ ] 8 — `./lab check 08-saturation-alert`
- [ ] 9 — `./lab check 09-too-many-connections` and `./lab check 09-wont-start`
- [ ] 10 — `./lab check 10-final-incident`, plus a written post-incident review

## What you will be able to do

By the end you can, on a MySQL 8.4 server you have never seen before:

- find where a setting came from and change it so it survives a restart;
- create least-privilege accounts that require TLS;
- find the session blocking everyone else, and decide whether to kill it;
- read an execution plan and design the composite index a query needs;
- rank a server's statements by total time and fix the worst offender;
- restore a backup and replay binary logs to the moment before a mistake,
  then prove the result with checksums;
- diagnose replication lag and repair a broken replica without leaving it
  inconsistent;
- write alert rules that fire on symptoms, and read a dashboard under load;
- get into a server that refuses connections, recover one that will not
  start, and write a blameless post-incident review.

The [curriculum](../../docs/curriculum.md) lists the outcomes per module and
how they were chosen.

## Scope and limits

This course teaches one MySQL primary with one asynchronous replica, on
MySQL 8.4 LTS Community Edition. It does not cover Group Replication or
InnoDB Cluster, automated failover, online schema change tools, proxies,
major-version upgrades or cloud-managed MySQL; those are planned for the
advanced course (see the [roadmap](../../docs/roadmap.md)). The lab is sized
for a laptop, so it shows mechanisms, not production-scale performance
numbers.

## Licence

The course text is licensed under
[Creative Commons Attribution 4.0](../../LICENSE-CONTENT): reuse and adapt
it, including commercially, with attribution to MoiToi.TECH. The lab code is
under the [Apache License 2.0](../../LICENSE).
