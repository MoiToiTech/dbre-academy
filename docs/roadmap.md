# Roadmap

What exists, what comes next, and what is deliberately left out. Status is
stated as it is: only the first course and the first incident challenge are
published. Everything below them is a plan, not material.

## Published

| Material | Status | Scope |
|---|---|---|
| [MySQL Production DBA Fundamentals](../courses/mysql-production-dba/README.md) | v1, free | Ten modules, about 13–15 hours, MySQL 8.4 LTS, Docker labs with automated checks |
| [Challenge #001: The database is slow. Nobody changed anything.](../challenges/001-slow-database/README.md) | v1, free | One production incident, 20–40 minutes, intermediate, MySQL 8.4, automated `verify` |

## Planned

### 1. MySQL in Production (advanced)

For people who have finished the fundamentals course or run MySQL daily.
Candidate topics, taken from the gaps in [research.md](research.md#44-deliberately-deferred):

- High availability beyond async replication: Group Replication, InnoDB
  Cluster and ClusterSet; automated failover and its failure modes
- Online schema change: `ALGORITHM=INSTANT`/`INPLACE`, gh-ost, pt-online-schema-change
- Connection routing and pooling: MySQL Router, ProxySQL
- Major-version upgrades (8.0 → 8.4, LTS → LTS) as a rehearsed procedure
- Data consistency checking between source and replicas
- Capacity planning and load testing (sysbench), OS and storage tuning
- Encryption at rest and in transit, auditing
- SLOs for a database service, error budgets, on-call design

### 2. TiDB Reliability Engineering

A specialised course for teams running TiDB: architecture (TiDB, TiKV, PD,
TiFlash), regions and placement, distributed transactions, hotspots,
backup and restore with BR, TiCDC, upgrades, observability, and incident
response on a distributed SQL database. Builds on the MySQL fundamentals:
TiDB speaks the MySQL protocol, and many diagnostic habits carry over.

### 3. Smaller additions to the fundamentals course

- Translations, starting with Estonian, if there is demand
- More scenarios per module (for example a metadata-lock pile-up during DDL,
  a disk-full incident) — contributions welcome, see
  [CONTRIBUTING.md](../CONTRIBUTING.md)

## Not planned

- A learning management system, accounts, certificates or progress tracking
  on a server. Progress is verified locally by `./lab check`.
- Paid tiers of this repository. The course stays free and openly licensed.
  Instructor-led training may be offered separately in future; it will not
  gate any material here.
- Vendor certification preparation. The course states outcomes as skills
  you can demonstrate, not exam objectives (see
  [research.md](research.md#45-certification-stance)).
