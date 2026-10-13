<p>
  <a href="https://moitoi.tech">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://moitoi.tech/brand/moitoi-tech-reverse.svg">
      <img src="https://moitoi.tech/brand/moitoi-tech-primary.svg" alt="MoiToi.TECH" width="200">
    </picture>
  </a>
</p>

# DBRE Academy

Free, open-source training in database reliability engineering, built on
labs you run on your own laptop. By [MoiToi.TECH](https://moitoi.tech).

[![checks](https://github.com/MoiToiTech/dbre-academy/actions/workflows/checks.yml/badge.svg)](https://github.com/MoiToiTech/dbre-academy/actions/workflows/checks.yml)
[![lab](https://github.com/MoiToiTech/dbre-academy/actions/workflows/lab.yml/badge.svg)](https://github.com/MoiToiTech/dbre-academy/actions/workflows/lab.yml)

## First course: MySQL Production DBA Fundamentals

`MySQL 8.4 LTS` · `10 modules` · `about 13–15 hours` · `free`

Learn to run MySQL in production by fixing real faults on a real server: a
blocked checkout, a slow query, a broken replica, a deleted table, a server
that refuses connections or will not start. Every exercise is checked by a
script, so you know when you have actually solved it.

**→ [Start the course](courses/mysql-production-dba/README.md)**

| # | Module | Exercise |
|---|---|---|
| 1 | [Architecture and MySQL internals](courses/mysql-production-dba/01-architecture/README.md) | Trace a connection, a change and a table through the server |
| 2 | [Installation, configuration and secure access](courses/mysql-production-dba/02-install-config-access/README.md) | Undo configuration drift; build a least-privilege account |
| 3 | [InnoDB transactions, MVCC and locking](courses/mysql-production-dba/03-innodb-transactions-locking/README.md) | Find and clear the session blocking checkout |
| 4 | [Execution plans and indexing](courses/mysql-production-dba/04-explain-indexing/README.md) | Design the index a dashboard query needs |
| 5 | [Performance diagnostics and slow queries](courses/mysql-production-dba/05-performance-diagnostics/README.md) | Find the statement eating the server under live load |
| 6 | [Backup, restore and data integrity](courses/mysql-production-dba/06-backup-restore/README.md) | Point-in-time recovery around an accidental `DELETE` |
| 7 | [Replication and high availability](courses/mysql-production-dba/07-replication-ha/README.md) | Fix replication lag; repair a broken replica |
| 8 | [Monitoring and observability](courses/mysql-production-dba/08-monitoring-observability/README.md) | Write the alert that should have fired |
| 9 | [Incident response and troubleshooting](courses/mysql-production-dba/09-incident-response/README.md) | Too many connections; a server that will not start |
| 10 | [Final challenge](courses/mysql-production-dba/10-final-challenge/README.md) | Three simultaneous faults and a post-incident review |

## Production Incident Challenges

One production incident each, solvable in under an hour on your laptop
without taking the course. The briefing is spoiler-free; the explanation
lives in a separate instructor guide. All challenges:
[challenges/README.md](challenges/README.md).

**[Challenge #001: The database is slow. Nobody changed anything.](challenges/001-slow-database/README.md)**
Your production database is slow. Can you figure out why?

`MySQL 8.4` · `intermediate` · `20–40 minutes` · `free`

## Who it is for

Linux system administrators, junior DBAs, backend developers, DevOps
engineers and SREs who look after MySQL, or are about to. You need a
terminal, basic SQL and Docker. No DBA experience is assumed.

## Start in ten minutes

You need Docker with Compose v2 (Docker Desktop, OrbStack, Colima or Docker
Engine) and about 4 GiB of memory for Docker. amd64 and arm64 (Apple
silicon) both work; on Windows, use WSL 2.

```bash
git clone https://github.com/MoiToiTech/dbre-academy.git
cd dbre-academy/labs
./lab doctor      # checks Docker, memory and ports
./lab up          # first run builds the lab image: ~2 minutes
./lab sql         # you are now root on the primary
```

Then open [module 1](courses/mysql-production-dba/01-architecture/README.md).

## Working with the lab

```bash
./lab status                          # what is running, is replication healthy
./lab scenario setup 04-missing-index # inject an exercise's fault
./lab check 04-missing-index          # did you fix it? exit code 0 = yes
./lab scenario reset 04-missing-index # put everything back
./lab reset                           # start completely fresh (~30 s)
./lab destroy                         # remove containers and data
./lab up --observability              # add Prometheus and Grafana
```

Ports bind to `127.0.0.1` only. Requirements, credentials, the dataset and
troubleshooting: [labs/README.md](labs/README.md).

## How progress is verified

There are no accounts and nothing is tracked. Your progress is the list of
`./lab check` commands that pass on your machine; the course README has a
[checklist](courses/mysql-production-dba/README.md#track-your-progress).
A passing check prints a link to share it on LinkedIn: self-reported, no
spoilers, and nothing is sent anywhere unless you post it.

The repository verifies itself the same way. On every change, CI starts the
lab from scratch on amd64 and arm64, runs every exercise's fault, check,
reference fix and reset, executes every command the lessons tell you to run,
and tears everything down.

## Problems and contributions

- Something does not work as the lesson says: [open a lab issue](https://github.com/MoiToiTech/dbre-academy/issues/new?template=lab-problem.yml).
- A technical claim is wrong or outdated: [open a content correction](https://github.com/MoiToiTech/dbre-academy/issues/new?template=content-correction.yml).
- Want to add a scenario or improve a lesson: read [CONTRIBUTING.md](CONTRIBUTING.md)
  and [docs/authoring.md](docs/authoring.md).

## What comes next

The [roadmap](docs/roadmap.md) plans an advanced *MySQL in Production*
course and a *TiDB Reliability Engineering* course. Neither exists yet. The
[curriculum](docs/curriculum.md) explains how the first course was designed,
and [research.md](docs/research.md) the benchmark behind it.

## Licence

| What | Licence |
|---|---|
| Course and challenge text: `courses/`, `challenges/`, `docs/` | [Creative Commons Attribution 4.0](LICENSE-CONTENT) |
| Code: `labs/`, `.github/`, scripts (including the challenge tooling in `challenges/`) | [Apache License 2.0](LICENSE) |

The MoiToi.TECH name and logo are not covered by either licence.

---

MoiToi.TECH — We build useful technology systems. · <https://moitoi.tech> ·
<connect@moitoi.tech>
