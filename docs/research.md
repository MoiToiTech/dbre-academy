# Curriculum benchmark: MySQL Production DBA Fundamentals

DBRE Academy (MoiToi.TECH) — research note, 2026-10-13.

## 1. Purpose and method

**Purpose.** We compared the planned first course, *MySQL Production DBA Fundamentals*
(8–12 h self-paced, MySQL 8.4 LTS, Docker labs, 10 modules), with established DBA training and with the
reliability-engineering literature. The goals were to:

- confirm that the module list covers what the industry treats as core DBA/DBRE skill;
- find gaps, and decide what to include now and what to defer to later courses;
- give course authors a verified primary reference list, mainly the MySQL 8.4 Reference Manual.

**Method.**

- We read the public course pages, datasheets and exam outlines of Percona, Oracle (MySQL 8.0 for
  Database Administrators course and 1Z0-908 exam), Dalibo (DBA1/DBA2/DBA3/PERF1), Data Egret
  (PostgreSQL Essentials DBA1) and EDB (Essentials / Advanced for PostgreSQL).
- We read the Google SRE book table of contents and its database-relevant chapters, plus the published chapter
  list of *Database Reliability Engineering* (Campbell & Majors, O'Reilly 2017).
- We sampled production DBA/DBRE job postings and summarised recurring requirements, without quoting them.
- Every `dev.mysql.com/doc/refman/8.4/en/` URL in §5 was fetched on 2026-10-13. Each returned HTTP 200 and an
  8.4 manual page title. dev.mysql.com returns HTTP 200 with a "Page Not Found" title for missing pages, so we
  checked the page title as well as the status code. Five candidate slugs did not exist and are left out.
- We used external material only to benchmark structure and learning outcomes. We copied nothing. Dalibo
  manuals are CC BY-NC-SA 2.0 FR and the Google SRE book is CC BY-NC-ND 4.0. Both licences forbid derivative
  or commercial reuse, so we may link to them but not adapt them.

**Conventions.**

- "not stated": the source page does not give this value.
- "unverified": the value comes only from a secondary source, or we could not load the primary page.

## 2. Provider-by-provider summary

| Provider | Course | Format / duration | Topics (summarised) | Lab approach | Licence / price | Source |
|---|---|---|---|---|---|---|
| Percona | MySQL Training for Database Operations Specialists | Instructor-led (on-site, virtual or blended); 2 days | Storage engines, flavours, built-in tools, Percona Toolkit; backup strategy (logical/physical, incremental, PITR, delayed replica, validating backups); replication (setup, internals, topologies, GTID, common problems, consistency); server troubleshooting and global status; PMM monitoring; security (OS/network, TLS, privileges, resource limits); InnoDB basics and internals (redo/undo, checkpoints, tablespaces, row formats, clustered index, AHI, change buffer, doublewrite, MVCC/row locking, tuning parameters) | "Hands-on exercises" (datasheet wording); environment not stated | Price not stated (contact sales) | [Percona training PDF](https://learn.percona.com/hubfs/Collateral/Training%20Docs/Percona_Training_MySQL.pdf), [percona.com/training](https://www.percona.com/training) |
| Percona | MySQL Training for Developers | 2 days | Query planning, EXPLAIN, composite indexes, finding unoptimised queries, joins/subqueries; application architecture (read/write split, sharding, connection management); schema design; SQL modes; partitioning; SQL injection | Hands-on (general claim) | Not stated | same PDF |
| Percona | DBA Hands-On (MySQL 101) | 2 days | Novice DBA basics: install, configure, source/replica setup, backups, troubleshooting | Hands-on (by title) | Not stated | same PDF |
| Percona | Group Replication 101; PXC Tutorial; ProxySQL Tutorial; PXC Operator on Kubernetes; MySQL for Oracle DBAs | 1–2 days each | Specialist HA, proxy and Kubernetes topics | Not stated | Not stated | same PDF |
| Oracle University | MySQL 8.0 for Database Administrators | 5 days (reseller pages; Oracle page not loadable) — **unverified** | Install/configure server and clients, architecture, user and security management, troubleshooting, backup/recovery, replication topologies, InnoDB Cluster HA | Not stated | Not stated | [learn.oracle.com learning path](https://learn.oracle.com/ols/learning-path/become-a-mysql-80-database-admin-professional/88337/97589) (JS-rendered, details not readable); [reseller outline](https://eta2u.ro/courses/ORA-MySQL-8.0-for-Database-Administrators) |
| Oracle | Exam 1Z0-908 *MySQL 8.0 Database Administrator* (OCP) | Proctored multiple choice; 73 questions / 120 min / 62 % pass / USD 245 — **unverified** (third-party prep site; education.oracle.com timed out) | Seven domains: Architecture; Server Installation & Configuration; Security; Monitoring & Maintenance; Query Optimization; Backups & Recovery; High Availability Techniques. Includes Enterprise-only tools (Enterprise Backup, Monitor, Audit, Firewall) and `mysqlpump` (removed in 8.4) | n/a (exam) | Price unverified | [dbexam.com syllabus](https://www.dbexam.com/oracle/oracle-1z0-908-certification-exam-syllabus) (secondary) |
| Dalibo | DBA1 *PostgreSQL Administration* | 3 days (21 h) on-site or 5 mornings (17.5 h) remote | History and community; feature discovery; installation; GUI and console tools; routine tasks; backup policy; backup and restore; monitoring ("Supervision") | Alternates theory and practicals (TP); exercise servers stay available in the afternoons; MCQ checks each morning | Inter-company €2,250 excl. VAT per trainee; intra-company €9,250 for up to 8. **Manual free, CC BY-NC-SA 2.0 FR** | [course page](https://dalibo.com/formation-administration), [manual](https://dali.bo/dba1_html) |
| Dalibo | DBA2 *PostgreSQL Avancé* | 3 days / 5 mornings | Architecture and files; configuration; memory and WAL; transaction engine and MVCC; VACUUM/autovacuum; partitioning intro; hot physical backup and PITR; **disaster handling** | Example exercises: inspect processes and files, observe cache, provoke locks, change isolation levels, observe MVCC, PITR restore, **provoke block corruption and try to recover** | Same prices; manual CC BY-NC-SA | [course page](https://dalibo.com/formation-postgresql-avance), [manual](https://dali.bo/dba2_pdf) |
| Dalibo | DBA3 *Backup and Replication* | 3 days / 5 mornings | Backup policy, PITR tooling, standby servers, physical and logical replication, switchover/failover, rebuilding an instance | TP (format as above) | Same prices; manual CC BY-NC-SA | [course page](https://dalibo.com/formation-postgresql-sauvegarde-restauration) |
| Dalibo | PERF1 *PostgreSQL Performances* | 3 days / 5 mornings | System and instance configuration; execution plans; indexing techniques; planner statistics; EXPLAIN; plan-node reference; analysis and diagnostics | TP | Same prices; manual CC BY-NC-SA | [course page](https://dalibo.com/formation-postgresql-performance-1), [manual](https://dali.bo/perf1_pdf) |
| Data Egret | PostgreSQL Essentials (DBA1) | Live online over Zoom, 5 × 3.5 h (17.5 h), not recorded | Project and community, ACID/MVCC/isolation concepts; installation and config files; daily operation (roles, privileges, VACUUM/ANALYZE/REINDEX, export/import); monitoring and diagnostics (logs, pg_stat_activity, pg_stat_statements, auto_explain, pgBadger) | **Instructor live demos**; participants need only Zoom (no student labs stated) | €850 excl. tax (Feb 2026 session, via OSB Alliance listing); not stated on dataegret.com | [dataegret.com](https://dataegret.com/courses-postgresql-essentials-dba1/), [OSB listing](https://osb-alliance.de/veranstaltungen/postgresql-essentials-for-dba-dba1-data-egret) |
| Data Egret | DBA2 Advanced; DBA3 Backups and Replication | Not stated | Named only | Not stated | Not stated | same |
| EDB | EDB Essentials for PostgreSQL | Instructor-led, private; 4 days | Architecture; installation; CLI tools; database clusters; configuration; data dictionary; databases; security; monitoring and admin tools; SQL primer; backup/recovery/PITR; routine maintenance; moving data; replication and HA tools | Not stated in datasheet | Contact for price; includes one certification attempt | [datasheet](https://www.enterprisedb.com/sites/default/files/2026-02/EDB-Essentials-For-PostgreSQL-Data-Sheet.pdf) |
| EDB | EDB Advanced for PostgreSQL | Instructor-led; 3 days | Monitoring; SQL tuning; performance tuning; benchmarking; extensions; partitioning; connection pooling; FDW; upgrade best practices | Not stated | Contact; one exam attempt | [datasheet](https://www.enterprisedb.com/sites/default/files/2026-02/EDB-Advanced-For-PostgreSQL.pdf) |
| Google | *Site Reliability Engineering* (book, free online) | 34 chapters | Database-relevant: ch 4 SLOs, 6 monitoring (four golden signals), 10 alerting, 11 on-call, 12 troubleshooting, 13 emergency response, 14 managing incidents, 15 postmortems, 21–22 overload and cascading failure, 26 data integrity | n/a | CC BY-NC-ND 4.0 | [sre.google TOC](https://sre.google/sre-book/table-of-contents/) |
| O'Reilly | *Database Reliability Engineering* (Campbell & Majors) | Book, 2017, 294 pp. | 13 chapters: Introducing DBRE; Service-Level Management; Risk Management; Operational Visibility; Infrastructure Engineering; Infrastructure Management; Backup and Recovery; Release Management; Security; Data Storage, Indexing and Replication; Datastore Field Guide; Data Architecture Sampler; Making the Case for DBRE | n/a | Commercial | Chapter list from secondary sources. oreilly.com returned 403, so chapter order and numbering are **unverified** |

### Observations

- **Time budgets.** Every paid DBA foundation course spends 17.5–35 contact hours: Dalibo and Data Egret
  17.5–21 h, Percona 2 days, EDB 4 days, Oracle 5 days. Our 8–12 h has to be selective. The most efficient use
  of that time is exercises, not long lectures.
- **Lab approaches.**
  - Dalibo and Percona: student exercises.
  - Data Egret: instructor demos only.
  - EDB and Oracle: lab format not stated.
  - None publishes a reproducible lab environment that learners can run themselves.
  - Our Docker labs, with failures injected by scripts, are a real point of difference.
- **Failure practice is rare.** Only Dalibo DBA2 publicly lists deliberate failure exercises (corruption,
  disaster handling). No foundation course publishes an incident-response or postmortem module. That material
  lives in the SRE and DBRE books.
- **The Oracle exam does not match 8.4.** 1Z0-908 targets MySQL 8.0 and leans on Enterprise Edition tools and
  `mysqlpump`. `mysqlpump` was removed in 8.4 ([What Is New in 8.4](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)).
  We use the exam as a coverage checklist only, not as a target.

## 3. Skills matrix

### Key

| Symbol | Meaning |
|---|---|
| Y | Covered in the published outline |
| P | Partly covered, or only implied |
| – | Not in the published outline (absence of evidence, not proof of absence) |

### Columns

| Column | Covers |
|---|---|
| Perc | Percona Ops Specialist (+ other Percona courses where noted) |
| Orcl | Oracle course / 1Z0-908 |
| Dal | Dalibo DBA1–3 + PERF1 |
| DE | Data Egret DBA1 |
| EDB | EDB Essentials + Advanced |
| SRE | Google SRE book |
| DBRE | Campbell & Majors |
| Ours | Our planned module |

| # | Core skill | Perc | Orcl | Dal | DE | EDB | SRE | DBRE | Ours |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Server process, memory and storage-engine architecture | Y | Y | Y | P | Y | – | Y | M1 |
| 2 | Install, option files, variables, start/stop | Y | Y | Y | Y | Y | – | P | M2 |
| 3 | Accounts, roles, auth plugins, TLS | Y | Y | Y | Y | Y | – | Y | M2 |
| 4 | Encryption at rest, audit, firewall | P | Y | – | – | P | – | Y | defer |
| 5 | Version upgrades and patching | – | Y | – | P | Y | – | P | defer (8.4 LTS model mentioned in M2) |
| 6 | Transactions, isolation, MVCC | Y | P | Y | Y | – | – | P | M3 |
| 7 | Locking, lock waits, deadlocks | Y | Y | Y | – | – | – | – | M3 |
| 8 | Redo/undo, checkpoints, crash recovery | Y | Y | Y | – | P | – | – | M1 + M3 |
| 9 | Routine maintenance (stats, purge/vacuum analogue) | P | Y | Y | Y | Y | – | – | M3 (purge/history list), M4 (ANALYZE) |
| 10 | Execution plans and EXPLAIN | Y (Dev) | Y | Y | P | Y | – | Y | M4 |
| 11 | Index design | Y (Dev) | Y | Y | – | P | – | Y | M4 |
| 12 | Slow-query and workload analysis | Y | Y | Y | Y | Y | – | Y | M5 |
| 13 | Server/OS configuration tuning | Y | Y | Y | – | Y | – | P | M5 (basics only) |
| 14 | Backup strategy, logical vs physical | Y | Y | Y | P | Y | Y | Y | M6 |
| 15 | Point-in-time recovery | Y | Y | Y | – | Y | P | Y | M6 |
| 16 | Restore testing and backup validation | Y | – | P | – | – | Y | Y | M6 |
| 17 | Data-consistency and corruption checks | Y | – | Y | – | – | Y | P | M6 |
| 18 | Replication setup, GTID, replica threads | Y | Y | Y | – | Y | – | Y | M7 |
| 19 | Replication lag and breakage troubleshooting | Y | Y | Y | – | P | – | P | M7 |
| 20 | Failover / switchover procedure | P | Y | Y | – | Y | – | Y | M7 (manual only) |
| 21 | Clustered HA (Group Replication / InnoDB Cluster / Galera) | Y (sep. courses) | Y | Y (HAPAT) | – | P | – | P | defer |
| 22 | Metrics, dashboards, exporters | Y (PMM) | Y (Ent. Monitor) | Y | Y | Y | Y | Y | M8 |
| 23 | Alerting design, golden signals | – | – | P | – | – | Y | Y | M8 |
| 24 | SLIs/SLOs for a database | – | – | – | – | – | Y | Y | M8 (intro) |
| 25 | Capacity planning, growth tracking | – | Y | – | – | P | P | Y | M8 (brief) |
| 26 | Incident response, triage runbooks | P | P | Y (disaster) | P | – | Y | P | M9, M10 |
| 27 | Blameless postmortems | – | – | – | – | – | Y | P | M9 |
| 28 | Online schema change / release management | P (Dev) | – | – | – | – | P | Y | defer |
| 29 | Connection pooling / proxies | Y (ProxySQL) | P (Router) | – | – | Y | P | P | defer |
| 30 | Partitioning | Y (Dev) | – | Y (intro) | – | Y | – | P | defer |
| 31 | IaC, config management, automation | – | – | – | – | – | Y | Y | defer (Docker Compose only) |
| 32 | Kubernetes operators | Y (sep.) | – | Y (CNPG1) | – | – | – | – | defer |
| 33 | Distributed SQL / data architecture choice | – | – | – | – | – | P | Y | defer (tidb-reliability) |

### Job-posting patterns (sampled 2026)

**Sample.** We sampled a Percona MySQL DBA posting (removed March 2026), a RELX "Senior DBA II" posting and the
GitLab handbook DBRE job family, plus search-result summaries of several Lever and Greenhouse DBRE postings.
The search-result summaries are secondary: we did not read the full postings. Requirements that recur:

1. **Linux and systems fundamentals**: shell, SSH, CPU/RAM/disk/IO reasoning. Every sampled posting had this.
2. **Replication and HA**: GTID replication, failover, semi-sync. Group Replication or Galera/PXC appear as a plus.
3. **Backups and recovery**: physical backups (XtraBackup by name) and PITR. Upgrades are often listed alongside.
4. **Query optimisation**: EXPLAIN and indexing, plus reviewing developers' SQL and schema migrations.
5. **Monitoring tools**: PMM, Grafana/Prometheus, Datadog, CloudWatch or Azure Monitor.
6. **Automation**: Ansible, Terraform, Python/Bash or Go. CI/CD familiarity is common for DBRE titles.
7. **Cloud and Kubernetes**: managed databases (RDS/Aurora, Azure) and Kubernetes. Usually nice-to-have at
   mid level, required at senior level.
8. **Operations practice**: on-call rotation, incident response, blameless RCA, runbooks and documentation.
   Senior roles add SLO definition and capacity planning.
9. **Percona Toolkit**: pt-online-schema-change, pt-table-checksum, pt-table-sync. Listed as nice-to-have in
   the MySQL-specific posting.
10. **Communication**: written English and explaining technical issues to people outside the field. Stated
    explicitly in the posting texts we read in full.

**Effect on our course.** Items 1–5 and 8 fall inside our scope, and the course covers them. Items 6–7 and
schema-change tooling are the main areas the course defers.

## 4. Gaps and decisions

### 4.1 Confirmed: the module list matches the field's consensus core

Architecture, configuration and access, transactions and locking, plans and indexes, diagnostics, backups,
replication and monitoring appear in every foundation curriculum we read. Modules 1–8 therefore need no
structural change.

### 4.2 Strengths to keep

| Strength | Why it matters |
|---|---|
| **M9 incident response and M10 incident challenge** | Only Dalibo DBA2 ("disaster handling", induced corruption) comes close among paid courses. Job postings consistently ask for on-call and RCA. Keep M9/M10 and frame them with SRE ch 12–15 vocabulary (triage, mitigation first, roles, blameless postmortem). |
| **Learner-run, reproducible Docker labs** | No provider publishes a self-hostable lab. Make each lab scriptable with `make break` / `make check`, so failures can be injected and outcomes checked automatically. |
| **Restore testing (M6)** | Covered by Percona and stressed by SRE ch 26 ("people want restores, not backups"), but missing from the Oracle and EDB outlines. Make "a restore you have actually performed and verified" an assessed outcome. |

### 4.3 Small additions inside the existing modules (no new module)

| Module | Add | Reason |
|---|---|---|
| M2 | MySQL release model (LTS vs Innovation; LTS gets 5 years premier + 3 years extended support); persisted variables (`SET PERSIST`); what changed in 8.4 that breaks old runbooks | 8.4 removed `mysqlpump`, `mysql_upgrade` and the `SLAVE`/`MASTER` statement aliases, and disables `mysql_native_password` by default. Learners following 8.0-era blog posts will hit these. |
| M3 | 8.4 InnoDB default changes (adaptive hash index OFF, change buffering `none`) | Percona's outline still teaches AHI and the change buffer as core internals; learners should know the 8.4 defaults differ. |
| M3 | Long-running transactions → history list length → purge lag | MySQL's analogue of the VACUUM/maintenance topic that every PostgreSQL course spends time on. |
| M4 | Unused/redundant index review via `sys` views; invisible indexes as a safe-drop technique | Low cost; directly useful in production. |
| M6 | Consistency check between source and replica (concept; `pt-table-checksum` named) | Percona Ops and job postings list it. |
| M7 | Replica lag measurement caveats; manual switchover runbook with GTID | Every HA curriculum covers this; full automation is deferred. |
| M8 | Four golden signals mapped to MySQL metrics; one SLI/SLO worked example; disk-growth trend | SRE ch 4/6 and DBRE ch 2/4. Only the books cover SLOs. |
| M9 | Short postmortem template exercise | SRE ch 15; GitLab's senior DBRE description expects RCAs. |

### 4.4 Deliberately deferred

| Topic | Defer to | Reason |
|---|---|---|
| Group Replication, InnoDB Cluster/ClusterSet, Galera/PXC, orchestrator-style automated failover | `mysql-production` advanced | Each is a 1–2 day course on its own at Percona and Dalibo. They need async replication fluency first. Note: `openark/orchestrator` is archived on GitHub (a Percona fork is active), so tooling choice needs its own discussion. |
| Online schema change (gh-ost, pt-osc, INSTANT DDL), release management | advanced | DBRE ch 8; needs indexing and replication background first. |
| ProxySQL / MySQL Router, connection pooling | advanced | Percona and EDB treat these as separate or advanced courses. |
| Major-version upgrades (8.0→8.4, LTS→LTS) | advanced | Oracle and EDB include upgrades, but a safe upgrade drill needs replication and backups first. M2 covers only awareness of the release model. |
| Encryption at rest, audit logging, firewall | advanced / security course | Mostly Enterprise Edition features in Oracle's exam; outside the time budget. |
| Terraform/Ansible, Kubernetes operators, cloud DBaaS specifics | advanced or a platform track | Postings want them, but they are platform skills, and none of the DBA foundation courses covers them. |
| Partitioning, sharding, distributed SQL, data-architecture choice | `tidb-reliability` and later courses | DBRE ch 10–12; fits the TiDB course better (distributed transactions, placement, region-level ops). |
| OS-level tuning (I/O schedulers, NUMA, filesystems) | advanced | Dalibo PERF1 and EDB Advanced material; low value without load tests. |

### 4.5 Certification stance

We do not align with 1Z0-908: it targets MySQL 8.0, relies on Enterprise tools, and covers removed
utilities. Course outcomes should be stated as observable skills: "restore to a point in time and prove row
counts match", rather than "knows mysqldump options".

## 5. Authoritative references per module

All `refman/8.4` URLs below were fetched on 2026-10-13 and returned the 8.4 manual page title shown.
`dev.mysql.com/doc/mysql-shell/8.4/...` URLs now redirect to **MySQL Shell 26.7**, and we cite them at their
redirected location.

### M1 — Architecture and internals

- 7.1 The MySQL Server — <https://dev.mysql.com/doc/refman/8.4/en/mysqld-server.html>
- 7.1.12 Connection Management — <https://dev.mysql.com/doc/refman/8.4/en/connection-management.html>
- 18.11 Overview of MySQL Storage Engine Architecture — <https://dev.mysql.com/doc/refman/8.4/en/pluggable-storage-overview.html>
- 16 MySQL Data Dictionary — <https://dev.mysql.com/doc/refman/8.4/en/data-dictionary.html>
- 17.1 Introduction to InnoDB — <https://dev.mysql.com/doc/refman/8.4/en/innodb-introduction.html>
- 17.2 InnoDB and the ACID Model — <https://dev.mysql.com/doc/refman/8.4/en/mysql-acid.html>
- 17.4 InnoDB Architecture — <https://dev.mysql.com/doc/refman/8.4/en/innodb-architecture.html>
- 17.5 InnoDB In-Memory Structures — <https://dev.mysql.com/doc/refman/8.4/en/innodb-in-memory-structures.html>
- 17.6 InnoDB On-Disk Structures — <https://dev.mysql.com/doc/refman/8.4/en/innodb-on-disk-structures.html>
- 17.6.2.1 Clustered and Secondary Indexes — <https://dev.mysql.com/doc/refman/8.4/en/innodb-index-types.html>
- 17.6.3 Tablespaces — <https://dev.mysql.com/doc/refman/8.4/en/innodb-tablespace.html>
- 10.12.3.1 How MySQL Uses Memory — <https://dev.mysql.com/doc/refman/8.4/en/memory-use.html>
- 7.4 MySQL Server Logs — <https://dev.mysql.com/doc/refman/8.4/en/server-logs.html>
- 1.4 What Is New in MySQL 8.4 since 8.0 — <https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html>

### M2 — Install, configure, secure access

- 1.3 MySQL Releases: Innovation and LTS — <https://dev.mysql.com/doc/refman/8.4/en/mysql-releases.html>
- 2.5.6 Deploying MySQL on Linux with Docker — <https://dev.mysql.com/doc/refman/8.4/en/linux-installation-docker.html>
- 2.5.6.1 Basic Steps for Docker Deployment — <https://dev.mysql.com/doc/refman/8.4/en/docker-mysql-getting-started.html>
- 2.9.1 Initializing the Data Directory — <https://dev.mysql.com/doc/refman/8.4/en/data-directory-initialization.html>
- 6.2.2.2 Using Option Files — <https://dev.mysql.com/doc/refman/8.4/en/option-files.html>
- 7.1.1 Configuring the Server — <https://dev.mysql.com/doc/refman/8.4/en/server-configuration.html>
- 7.1.8 Server System Variables — <https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html>
- 7.1.9.3 Persisted System Variables — <https://dev.mysql.com/doc/refman/8.4/en/persisted-system-variables.html>
- 8.1.1 Security Guidelines — <https://dev.mysql.com/doc/refman/8.4/en/security-guidelines.html>
- 8.2 Access Control and Account Management — <https://dev.mysql.com/doc/refman/8.4/en/access-control.html>
- 8.2.2 Privileges Provided by MySQL — <https://dev.mysql.com/doc/refman/8.4/en/privileges-provided.html>
- 8.2.10 Using Roles — <https://dev.mysql.com/doc/refman/8.4/en/roles.html>
- 8.2.15 Password Management — <https://dev.mysql.com/doc/refman/8.4/en/password-management.html>
- 8.4.1.2 Caching SHA-2 Pluggable Authentication — <https://dev.mysql.com/doc/refman/8.4/en/caching-sha2-pluggable-authentication.html>
- 8.3.1 Configuring Encrypted Connections — <https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html>
- 15.7.1.3 CREATE USER — <https://dev.mysql.com/doc/refman/8.4/en/create-user.html>
- 15.7.1.6 GRANT — <https://dev.mysql.com/doc/refman/8.4/en/grant.html>
- 6.4.2 mysql_secure_installation — <https://dev.mysql.com/doc/refman/8.4/en/mysql-secure-installation.html>
- Docker Official Image `mysql` (tags `8.4`, `8.4.x`; 8.4.11 observed) — <https://hub.docker.com/_/mysql>

### M3 — InnoDB, transactions, MVCC, locking

- 17.3 InnoDB Multi-Versioning — <https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html>
- 17.7.1 InnoDB Locking — <https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html>
- 17.7.2 InnoDB Transaction Model — <https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-model.html>
- 17.7.2.1 Transaction Isolation Levels — <https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html>
- 17.7.2.2 autocommit, Commit, and Rollback — <https://dev.mysql.com/doc/refman/8.4/en/innodb-autocommit-commit-rollback.html>
- 17.7.2.3 Consistent Nonlocking Reads — <https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html>
- 17.7.3 Locks Set by Different SQL Statements — <https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html>
- 17.7.5 Deadlocks in InnoDB — <https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks.html>
- 17.7.5.2 Deadlock Detection — <https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlock-detection.html>
- 17.5.1 Buffer Pool — <https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool.html>
- 17.6.4 Doublewrite Buffer — <https://dev.mysql.com/doc/refman/8.4/en/innodb-doublewrite-buffer.html>
- 17.6.5 Redo Log — <https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html>
- 17.6.6 Undo Logs — <https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-logs.html>
- 17.8.9 Purge Configuration — <https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html>
- 17.18.2 InnoDB Recovery — <https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html>
- 29.12.13.1 performance_schema.data_locks — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-data-locks-table.html>
- 30.4.3.9 sys.innodb_lock_waits — <https://dev.mysql.com/doc/refman/8.4/en/sys-innodb-lock-waits.html>
- 28.4.28 INFORMATION_SCHEMA.INNODB_TRX — <https://dev.mysql.com/doc/refman/8.4/en/information-schema-innodb-trx-table.html>
- 17.17.3 InnoDB Standard Monitor and Lock Monitor Output — <https://dev.mysql.com/doc/refman/8.4/en/innodb-standard-monitor.html>

### M4 — EXPLAIN and indexing

- 10.8.1 Optimizing Queries with EXPLAIN — <https://dev.mysql.com/doc/refman/8.4/en/using-explain.html>
- 10.8.2 EXPLAIN Output Format — <https://dev.mysql.com/doc/refman/8.4/en/explain-output.html>
- 15.8.2 EXPLAIN Statement (incl. EXPLAIN ANALYZE) — <https://dev.mysql.com/doc/refman/8.4/en/explain.html>
- 10.3 Optimization and Indexes — <https://dev.mysql.com/doc/refman/8.4/en/optimization-indexes.html>
- 10.3.1 How MySQL Uses Indexes — <https://dev.mysql.com/doc/refman/8.4/en/mysql-indexes.html>
- 10.3.6 Multiple-Column Indexes — <https://dev.mysql.com/doc/refman/8.4/en/multiple-column-indexes.html>
- 10.3.12 Invisible Indexes — <https://dev.mysql.com/doc/refman/8.4/en/invisible-indexes.html>
- 10.3.13 Descending Indexes — <https://dev.mysql.com/doc/refman/8.4/en/descending-indexes.html>
- 10.2.1.6 Index Condition Pushdown — <https://dev.mysql.com/doc/refman/8.4/en/index-condition-pushdown-optimization.html>
- 10.9.3 Optimizer Hints — <https://dev.mysql.com/doc/refman/8.4/en/optimizer-hints.html>
- 10.9.6 Optimizer Statistics (histograms) — <https://dev.mysql.com/doc/refman/8.4/en/optimizer-statistics.html>
- 10.15 Tracing the Optimizer — <https://dev.mysql.com/doc/refman/8.4/en/optimizer-tracing.html>
- 15.7.3.1 ANALYZE TABLE — <https://dev.mysql.com/doc/refman/8.4/en/analyze-table.html>
- 17.8.10.1 Persistent Optimizer Statistics — <https://dev.mysql.com/doc/refman/8.4/en/innodb-persistent-stats.html>
- 30.4.3.32 sys.schema_unused_indexes — <https://dev.mysql.com/doc/refman/8.4/en/sys-schema-unused-indexes.html>
- 30.4.3.27 sys.schema_redundant_indexes — <https://dev.mysql.com/doc/refman/8.4/en/sys-schema-redundant-indexes.html>
- Sample data: Employees DB <https://dev.mysql.com/doc/employee/en/> (source <https://github.com/datacharmer/test_db>), Sakila <https://dev.mysql.com/doc/sakila/en/>

### M5 — Performance diagnostics and slow queries

- 7.4.5 The Slow Query Log — <https://dev.mysql.com/doc/refman/8.4/en/slow-query-log.html>
- 6.6.10 mysqldumpslow — <https://dev.mysql.com/doc/refman/8.4/en/mysqldumpslow.html>
- 29 MySQL Performance Schema — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema.html>
- 29.1 Performance Schema Quick Start — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-quick-start.html>
- 29.4.4 Pre-Filtering by Instrument — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-instrument-filtering.html>
- 29.10 Statement Digests and Sampling — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-digests.html>
- 29.12.4 Wait Event Tables — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-wait-tables.html>
- 29.12.22.8 threads Table — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-threads-table.html>
- 30 MySQL sys Schema — <https://dev.mysql.com/doc/refman/8.4/en/sys-schema.html>
- 30.2 Using the sys Schema — <https://dev.mysql.com/doc/refman/8.4/en/sys-schema-usage.html>
- 30.4.3.35 sys.statement_analysis — <https://dev.mysql.com/doc/refman/8.4/en/sys-statement-analysis.html>
- 15.7.7.31 SHOW PROCESSLIST — <https://dev.mysql.com/doc/refman/8.4/en/show-processlist.html>
- 15.7.7.16 SHOW ENGINE — <https://dev.mysql.com/doc/refman/8.4/en/show-engine.html>
- 10 Optimization (chapter root) — <https://dev.mysql.com/doc/refman/8.4/en/optimization.html>
- 17.8.3.1 Configuring Buffer Pool Size — <https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool-resize.html>
- 17.14 InnoDB Startup Options and System Variables — <https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html>
- Percona Toolkit pt-query-digest — <https://docs.percona.com/percona-toolkit/pt-query-digest.html>

### M6 — Backup, restore, integrity

- 9 Backup and Recovery — <https://dev.mysql.com/doc/refman/8.4/en/backup-and-recovery.html>
- 9.1 Backup and Recovery Types — <https://dev.mysql.com/doc/refman/8.4/en/backup-types.html>
- 9.2 Database Backup Methods — <https://dev.mysql.com/doc/refman/8.4/en/backup-methods.html>
- 9.3 Example Backup and Recovery Strategy — <https://dev.mysql.com/doc/refman/8.4/en/backup-strategy-example.html>
- 9.5 Point-in-Time (Incremental) Recovery — <https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery.html>
- 9.5.1 PITR Using Binary Log — <https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery-binlog.html>
- 7.4.4 The Binary Log — <https://dev.mysql.com/doc/refman/8.4/en/binary-log.html>
- 6.5.4 mysqldump — <https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html>
- 6.6.9 mysqlbinlog — <https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html>
- 7.6.7 The Clone Plugin — <https://dev.mysql.com/doc/refman/8.4/en/clone-plugin.html>
- 17.18.1 InnoDB Backup — <https://dev.mysql.com/doc/refman/8.4/en/innodb-backup.html>
- 15.7.3.2 CHECK TABLE — <https://dev.mysql.com/doc/refman/8.4/en/check-table.html>
- 6.5.3 mysqlcheck — <https://dev.mysql.com/doc/refman/8.4/en/mysqlcheck.html>
- 6.6.2 innochecksum — <https://dev.mysql.com/doc/refman/8.4/en/innochecksum.html>
- 17.20.3 Forcing InnoDB Recovery — <https://dev.mysql.com/doc/refman/8.4/en/forcing-innodb-recovery.html>
- MySQL Shell dump/load utilities (redirects to Shell 26.7) — <https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-dump-instance-schema.html>, <https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-load-dump.html>
- Percona XtraBackup 8.4 — <https://docs.percona.com/percona-xtrabackup/8.4/> (supports only 8.4-series servers, not 8.0/9.x, and only databases created on 8.4; pages: [full backup](https://docs.percona.com/percona-xtrabackup/8.4/create-full-backup.html), [prepare](https://docs.percona.com/percona-xtrabackup/8.4/prepare-full-backup.html), [restore](https://docs.percona.com/percona-xtrabackup/8.4/restore-a-backup.html), [incremental](https://docs.percona.com/percona-xtrabackup/8.4/create-incremental-backup.html))
- Percona Toolkit pt-table-checksum — <https://docs.percona.com/percona-toolkit/pt-table-checksum.html>
- Google SRE ch 26 Data Integrity — <https://sre.google/sre-book/data-integrity/>

### M7 — Replication and HA fundamentals

- 19 Replication — <https://dev.mysql.com/doc/refman/8.4/en/replication.html>
- 19.1 Configuring Replication — <https://dev.mysql.com/doc/refman/8.4/en/replication-configuration.html>
- 19.1.2 Binary-Log-Position Replication Setup — <https://dev.mysql.com/doc/refman/8.4/en/replication-howto.html>
- 19.1.3 Replication with GTIDs — <https://dev.mysql.com/doc/refman/8.4/en/replication-gtids.html>
- 19.1.3.1 GTID Format and Storage — <https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-concepts.html>
- 19.1.3.4 Setting Up Replication Using GTIDs — <https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-howto.html>
- 19.1.6.3 Replica Server Options and Variables — <https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html>
- 19.1.7.1 Checking Replication Status — <https://dev.mysql.com/doc/refman/8.4/en/replication-administration-status.html>
- 19.2 Replication Implementation — <https://dev.mysql.com/doc/refman/8.4/en/replication-implementation.html>
- 19.2.1 Replication Formats — <https://dev.mysql.com/doc/refman/8.4/en/replication-formats.html>
- 7.4.4.1 Binary Logging Formats — <https://dev.mysql.com/doc/refman/8.4/en/binary-log-formats.html>
- 19.2.3 Replication Threads — <https://dev.mysql.com/doc/refman/8.4/en/replication-threads.html>
- 19.4.1 Using Replication for Backups — <https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-backups.html>
- 19.4.2 Handling an Unexpected Halt of a Replica — <https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-unexpected-replica-halt.html>
- 19.4.8 Switching Sources During Failover — <https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-switch.html>
- 19.4.10 Semisynchronous Replication — <https://dev.mysql.com/doc/refman/8.4/en/replication-semisync.html>
- 19.4.11 Delayed Replication — <https://dev.mysql.com/doc/refman/8.4/en/replication-delayed.html>
- 19.5.4 Troubleshooting Replication — <https://dev.mysql.com/doc/refman/8.4/en/replication-problems.html>
- 15.4.2.2 CHANGE REPLICATION SOURCE TO — <https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html>
- 15.7.7.35 SHOW REPLICA STATUS — <https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html>
- 29.12.11 Performance Schema Replication Tables — <https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-tables.html>
- Forward pointers (deferred): 20 Group Replication <https://dev.mysql.com/doc/refman/8.4/en/group-replication.html>; InnoDB Cluster <https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-innodb-cluster.html>; InnoDB ReplicaSet <https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-innodb-replicaset.html>; MySQL Router 8.4 <https://dev.mysql.com/doc/mysql-router/8.4/en/>
- Percona Toolkit pt-heartbeat (lag measurement) — <https://docs.percona.com/percona-toolkit/pt-heartbeat.html>

### M8 — Monitoring and observability

- 7.1.10 Server Status Variables — <https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html>
- 7.4.2 The Error Log — <https://dev.mysql.com/doc/refman/8.4/en/error-log.html>
- 7.4.3 The General Query Log — <https://dev.mysql.com/doc/refman/8.4/en/query-log.html>
- 28 INFORMATION_SCHEMA Tables — <https://dev.mysql.com/doc/refman/8.4/en/information-schema.html>
- 28.4.21 INFORMATION_SCHEMA.INNODB_METRICS — <https://dev.mysql.com/doc/refman/8.4/en/information-schema-innodb-metrics-table.html>
- 17.15.6 InnoDB INFORMATION_SCHEMA Metrics Table — <https://dev.mysql.com/doc/refman/8.4/en/innodb-information-schema-metrics-table.html>
- 17.16 InnoDB Integration with Performance Schema — <https://dev.mysql.com/doc/refman/8.4/en/innodb-performance-schema.html>
- Prometheus mysqld_exporter README (latest release v0.20.0, 2026-08-13; MySQL ≥ 5.6; exporter user needs `PROCESS, REPLICATION CLIENT, SELECT`, README recommends `MAX_USER_CONNECTIONS 3`) — <https://github.com/prometheus/mysqld_exporter>
- Prometheus alerting practices — <https://prometheus.io/docs/practices/alerting/>
- Percona Monitoring and Management docs — <https://docs.percona.com/percona-monitoring-and-management/>
- Google SRE ch 4 SLOs <https://sre.google/sre-book/service-level-objectives/>; ch 6 Monitoring <https://sre.google/sre-book/monitoring-distributed-systems/>; ch 10 Practical Alerting <https://sre.google/sre-book/practical-alerting/>; Workbook Implementing SLOs <https://sre.google/workbook/implementing-slos/>

### M9 — Incident response

- B.3 Problems and Common Errors — <https://dev.mysql.com/doc/refman/8.4/en/problems.html>
- B.3.2.5 Too many connections — <https://dev.mysql.com/doc/refman/8.4/en/too-many-connections.html>
- B.3.2.7 MySQL server has gone away — <https://dev.mysql.com/doc/refman/8.4/en/gone-away.html>
- B.3.3.3 What to Do If MySQL Keeps Crashing — <https://dev.mysql.com/doc/refman/8.4/en/crashing.html>
- B.3.3.4 How MySQL Handles a Full Disk — <https://dev.mysql.com/doc/refman/8.4/en/full-disk.html>
- B.3.3.5 Where MySQL Stores Temporary Files — <https://dev.mysql.com/doc/refman/8.4/en/temporary-files.html>
- B.1 Error Message Sources and Elements — <https://dev.mysql.com/doc/refman/8.4/en/error-message-elements.html>
- 17.20 InnoDB Troubleshooting — <https://dev.mysql.com/doc/refman/8.4/en/innodb-troubleshooting.html>
- 15.7.8.4 KILL — <https://dev.mysql.com/doc/refman/8.4/en/kill.html>
- 6.5.2 mysqladmin — <https://dev.mysql.com/doc/refman/8.4/en/mysqladmin.html>
- 7.1.19 The Server Shutdown Process — <https://dev.mysql.com/doc/refman/8.4/en/server-shutdown.html>
- Percona Toolkit pt-stalk <https://docs.percona.com/percona-toolkit/pt-stalk.html>, pt-kill <https://docs.percona.com/percona-toolkit/pt-kill.html>
- Google SRE ch 12 Effective Troubleshooting <https://sre.google/sre-book/effective-troubleshooting/>; ch 13 Emergency Response <https://sre.google/sre-book/emergency-response/>; ch 14 Managing Incidents <https://sre.google/sre-book/managing-incidents/>; ch 15 Postmortem Culture <https://sre.google/sre-book/postmortem-culture/>; ch 22 Cascading Failures <https://sre.google/sre-book/addressing-cascading-failures/>; Workbook Incident Response <https://sre.google/workbook/incident-response/>

### M10 — Final incident challenge

No new manual sections. Scenarios should combine pages already cited, for example:

- full disk + binlog purge;
- lock pile-up from a long transaction;
- replica broken by a duplicate key;
- PITR after an accidental `DELETE`.

Glossary for consistent terminology: <https://dev.mysql.com/doc/refman/8.4/en/glossary.html>

**Candidate slugs that do not exist in the 8.4 manual** (do not cite):

- `explain-analyze.html` (EXPLAIN ANALYZE is documented in `explain.html`)
- `general-query-log.html` (use `query-log.html`)
- `server-error-reference.html`
- `group-replication-introduction.html`
- `performance-schema-events-statements-summary-tables.html`
- `refman/8.4/en/mysql-shell.html`
- `refman/8.4/en/mysqlpump.html` (this one redirects to the 8.0 manual)

## 6. Sources (all accessed 2026-10-13)

### Training providers

- Percona — Training overview: <https://www.percona.com/training> ; "Percona Training for MySQL" PDF: <https://learn.percona.com/hubfs/Collateral/Training%20Docs/Percona_Training_MySQL.pdf>
- Oracle — learning path (content JS-rendered, not readable): <https://learn.oracle.com/ols/learning-path/become-a-mysql-80-database-admin-professional/88337/97589> ; exam page <https://education.oracle.com/mysql-8-0-database-administrator/pexam_1Z0-908> (timed out — **not verified**)
- Oracle 1Z0-908 syllabus (secondary): <https://www.dbexam.com/oracle/oracle-1z0-908-certification-exam-syllabus> ; course reseller outline (secondary): <https://eta2u.ro/courses/ORA-MySQL-8.0-for-Database-Administrators>
- Dalibo — catalogue: <https://dalibo.com/formations> ; DBA1 <https://dalibo.com/formation-administration> ; DBA2 <https://dalibo.com/formation-postgresql-avance> ; DBA3 <https://dalibo.com/formation-postgresql-sauvegarde-restauration> ; PERF1 <https://dalibo.com/formation-postgresql-performance-1> ; DBA1 programme sheet <https://public.dalibo.com/commercial/formations/formation-administration.pdf> ; manuals <https://dali.bo/dba1_html> , <https://dali.bo/dba2_pdf> , <https://dali.bo/perf1_pdf> ; licence <https://creativecommons.org/licenses/by-nc-sa/2.0/fr/>
- Data Egret — <https://dataegret.com/courses-postgresql-essentials-dba1/> ; OSB Alliance event listing <https://osb-alliance.de/veranstaltungen/postgresql-essentials-for-dba-dba1-data-egret>
- EDB — Essentials datasheet <https://www.enterprisedb.com/sites/default/files/2026-02/EDB-Essentials-For-PostgreSQL-Data-Sheet.pdf> ; Advanced datasheet <https://www.enterprisedb.com/sites/default/files/2026-02/EDB-Advanced-For-PostgreSQL.pdf>

### Books

- Google SRE book TOC: <https://sre.google/sre-book/table-of-contents/> (CC BY-NC-ND 4.0); SRE Workbook TOC: <https://sre.google/workbook/table-of-contents/>
- *Database Reliability Engineering*, Campbell & Majors, O'Reilly, 2017, ISBN 978-1491925942: <https://www.oreilly.com/library/view/database-reliability-engineering/9781491925935/> (403 — chapter list taken from <https://www.i-programmer.info/book-watch-archive/11372-database-reliability-engineering-oreilly.html> and search-index snippets; **unverified against the publisher**)

### Job postings (patterns only)

- Percona MySQL DBA (EMEA), removed 2026-03-24: <https://builtin.com/job/mysql-dba-emea/6270546>
- RELX Senior DBA II: <https://www.builtinnyc.com/job/senior-dba-ii/11562542>
- GitLab DBRE job family: <https://handbook.gitlab.com/job-description-library/engineering/infrastructure/database-reliability-engineer/>
- Lever/Greenhouse DBRE postings: seen as search snippets only; the full postings returned 404 when fetched (**unverified**)

### Tooling and documentation

- MySQL 8.4 Reference Manual (every URL in §5): <https://dev.mysql.com/doc/refman/8.4/en/>
- MySQL 8.4 Release Notes: <https://dev.mysql.com/doc/relnotes/mysql/8.4/en/>
- MySQL Shell (8.4 path redirects to 26.7): <https://dev.mysql.com/doc/mysql-shell/26.7/en/>
- Docker Official Image `mysql`: <https://hub.docker.com/_/mysql>
- Prometheus mysqld_exporter: <https://github.com/prometheus/mysqld_exporter>
- Percona XtraBackup 8.4: <https://docs.percona.com/percona-xtrabackup/8.4/>
- Percona Toolkit: <https://docs.percona.com/percona-toolkit/pt-query-digest.html> (and pt-table-checksum, pt-heartbeat, pt-stalk, pt-kill, pt-online-schema-change pages)
- Percona Monitoring and Management: <https://docs.percona.com/percona-monitoring-and-management/>
- orchestrator: <https://github.com/openark/orchestrator> (archived; last push 2025-02-18); active fork <https://github.com/percona/orchestrator>
