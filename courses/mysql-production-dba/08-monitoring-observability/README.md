# Module 8 — Monitoring and observability

`time: ~90 min` · `lab: ./lab up --observability` then `./lab scenario setup 08-saturation-alert` · `level: fundamentals`

Monitoring is how you find out that something is wrong before a customer
tells you, and how you know where to look when they do. For a database that
means a small set of signals — throughput, latency, errors, saturation,
replication health — collected continuously, kept long enough to compare
with last week, and turned into a few alerts that wake someone up only when
a person needs to act. This module builds that with the standard open-source
stack — `mysqld_exporter`, Prometheus and Grafana — and spends as much time
on what the numbers *mean* as on how to collect them.

## Learning objectives

By the end of this module you can:

- name the signals that describe a MySQL server's health and where each one
  comes from;
- explain why `Seconds_Behind_Source` can read 0 or vanish while a replica
  is broken, and what to measure instead;
- describe how `mysqld_exporter` and Prometheus collect metrics, and set up
  a least-privilege monitoring account;
- write Prometheus alert rules that are symptom-based, actionable and
  tested, with `for:` durations, severities and runbook links;
- read the lab's Grafana dashboard and find a fault from metrics alone.

## Prerequisites

- Modules 3, 5 and 7: locks, statement digests, replication.
- The lab with the observability profile. If it is running without it,
  `./lab up --observability` adds the four extra containers and keeps your
  data. Check that Prometheus is up and scraping both exporters:

```bash test
curl -sf "http://127.0.0.1:${DBRE_PROMETHEUS_PORT:-19090}/-/ready" \
  || { echo "Prometheus not reachable: run ./lab up --observability"; exit 1; }
./lab exec prometheus promtool query instant http://localhost:9090 'up{job="mysql"}'
```

```text
Prometheus Server is Ready.
up{instance="replica", job="mysql", role="replica"} => 1 @[1791889157.307]
up{instance="primary", job="mysql", role="primary"} => 1 @[1791889157.307]
```

Prometheus is at `http://127.0.0.1:19090`, Grafana at
`http://127.0.0.1:13000` (anonymous viewer access; `admin` /
`dbre-lab-grafana` to edit). Ports differ if you set `DBRE_*_PORT`.

The `promtool query instant` form used throughout runs PromQL inside the
Prometheus container and prints plain text, so you need neither `jq` nor
the browser. Every query also works in the Prometheus UI's *Graph* tab.

## The pipeline

```text
 mysqld (primary)  <-- SQL every scrape --  mysqld_exporter  <-- HTTP GET /metrics --+
 mysqld (replica)  <-- SQL every scrape --  mysqld_exporter  <-- HTTP GET /metrics --+
                                                                                     |
                     Grafana  -- PromQL -->  Prometheus (TSDB, rules, alerts) -------+
```

- **[mysqld_exporter](https://github.com/prometheus/mysqld_exporter)** is a
  small Go program. On each scrape it connects to MySQL, runs `SHOW GLOBAL
  STATUS`, `SHOW GLOBAL VARIABLES`, `SHOW REPLICA STATUS` and a few
  `information_schema` / `performance_schema` queries, and translates the
  results into Prometheus metrics. It stores nothing.
- **Prometheus** scrapes every exporter every 5 s in the lab
  ([`prometheus.yml`](../../../labs/observability/prometheus/prometheus.yml)),
  stores the samples, and evaluates rule files on the same interval.
- **Grafana** queries Prometheus to draw dashboards. It is a viewer; the
  alerting in this lab is done by Prometheus rules.

A pull model has a useful property: if the exporter or the network dies,
Prometheus notices — the target's `up` series goes to 0. Monitoring that
fails silently is worse than none.

### A least-privilege monitoring account

The exporter logs in as `exporter`, created by the lab's init script with
the grants its README recommends:

```sql test
SHOW GRANTS FOR 'exporter'@'%';
SELECT user, host, max_user_connections FROM mysql.user WHERE user = 'exporter';
```

```text
+--------------------------------------------------------------------+
| Grants for exporter@%                                              |
+--------------------------------------------------------------------+
| GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO `exporter`@`%` |
+--------------------------------------------------------------------+
+----------+------+----------------------+
| user     | host | max_user_connections |
+----------+------+----------------------+
| exporter | %    |                    3 |
+----------+------+----------------------+
```

- `PROCESS` — to see other sessions' threads and InnoDB status.
- `REPLICATION CLIENT` — for `SHOW REPLICA STATUS` and binary log status.
- `SELECT ON *.*` — for `performance_schema` and `information_schema`.
  This is broader than it looks: it can read every table, including
  application data. Where that matters, grant `SELECT` on
  `performance_schema.*` and the specific `sys` views instead, and check
  that each collector you enable still works.
- `MAX_USER_CONNECTIONS 3` — a monitoring bug must never be able to use up
  `max_connections` during the incident you are trying to watch.

No `SUPER`, no write privileges, no `CONNECTION_ADMIN` (which would let it
in when the server is full — tempting, but then a misbehaving exporter
competes with the DBA for the reserved connection).

### What the exporter emits

Look at the raw text Prometheus scrapes:

```bash test
./lab exec prometheus wget -qO- http://exporter-primary:9104/metrics \
  | grep -E '^(# (HELP|TYPE) )?mysql_global_status_threads_running|^mysql_up '
```

```text
# HELP mysql_global_status_threads_running Generic metric from SHOW GLOBAL STATUS.
# TYPE mysql_global_status_threads_running untyped
mysql_global_status_threads_running 4
mysql_up 1
```

Each `SHOW GLOBAL STATUS` variable becomes `mysql_global_status_<name>`,
each variable `mysql_global_variables_<name>`. The exporter marks most of
them `untyped`: it cannot know which status variables are counters. You
have to — `Questions` only ever rises (use `rate()`), `Threads_running`
goes up and down (use it as is).

## What to measure

Group the signals the way you will use them. Every row below is a panel on
the lab dashboard.

| Signal | MySQL source | Prometheus metric / query |
|---|---|---|
| Throughput | `Questions`, `Com_*` | `rate(mysql_global_status_questions[1m])`, `mysql_global_status_commands_total` |
| Latency | statement digests and histograms | not exported by default — see below |
| Errors | `Aborted_connects`, `Connection_errors_*`, statement errors | `mysql_global_status_aborted_connects`, `..._connection_errors_total` |
| Saturation | `Threads_running`, `Threads_connected`, buffer pool, lock waits, history list, redo | see the saturation section |
| Replication | `SHOW REPLICA STATUS`, GTID sets | `mysql_slave_status_*` |

### Throughput

```bash test
./lab exec prometheus promtool query instant \
  http://localhost:9090 'rate(mysql_global_status_questions[1m])'
```

```text
{instance="replica", job="mysql", role="replica"} => 5.181912398407245 @[1791889157.475]
{instance="primary", job="mysql", role="primary"} => 5.527574231321709 @[1791889157.475]
```

`Questions` counts statements sent by clients
([manual: server status variables](https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html));
the `Com_*` family splits them by type. Throughput on its own is neither
good nor bad. Its value is as a baseline: a drop to zero is an outage
somewhere upstream, a doubling is a new feature, a retry storm or a
crawler. Compare with the same time last week, not with a fixed number.

### Latency

`SHOW GLOBAL STATUS` has no latency. The server's own latency record is
the Performance Schema (module 5): per-digest totals and percentiles, and a
server-wide histogram of statement latency,
[`events_statements_histogram_global`](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-histogram-summary-tables.html).
Percentiles come straight out of it:

```sql test
SELECT q.quantile,
       format_pico_time((SELECT MIN(BUCKET_TIMER_HIGH)
                         FROM performance_schema.events_statements_histogram_global
                         WHERE BUCKET_QUANTILE >= q.quantile)) AS no_slower_than
FROM (SELECT 0.50 AS quantile UNION ALL SELECT 0.95 UNION ALL SELECT 0.99) q;
```

```text
+----------+----------------+
| quantile | no_slower_than |
+----------+----------------+
|     0.50 | 54.95 us       |
|     0.95 | 11.48 ms       |
|     0.99 | 19.05 ms       |
+----------+----------------+
```

This histogram is cumulative since start-up, so it answers "what has
latency been like", not "what is it now". `mysqld_exporter` can export
per-digest statistics (`--collect.perf_schema.eventsstatements`), but each
digest becomes a set of time series; with thousands of query shapes that
is a cardinality problem for Prometheus, and the lab leaves it off. Two
common answers in production:

- measure latency in the application (a histogram per endpoint or query
  name), which is what users experience anyway; and
- keep the digest tables for diagnosis, and alert on symptoms you can
  measure cheaply — throughput, errors, saturation.

### Errors

Connection-level errors are exported as counters
(`mysql_global_status_aborted_connects`,
`mysql_global_status_connection_errors_total{error="max_connections"}`).
Statement errors live in the Performance Schema, broken down by account
and error number:

```sql test
SELECT USER, ERROR_NUMBER, ERROR_NAME, SUM_ERROR_RAISED
FROM performance_schema.events_errors_summary_by_user_by_error
WHERE SUM_ERROR_RAISED > 0
ORDER BY SUM_ERROR_RAISED DESC
LIMIT 6;
```

```text
+----------+--------------+----------------------------+------------------+
| USER     | ERROR_NUMBER | ERROR_NAME                 | SUM_ERROR_RAISED |
+----------+--------------+----------------------------+------------------+
| exporter |         1064 | ER_PARSE_ERROR             |             1176 |
| exporter |         3554 | ER_NO_SYSTEM_TABLE_ACCESS  |              882 |
| app      |         1064 | ER_PARSE_ERROR             |              592 |
| exporter |         1052 | ER_NON_UNIQ_ERROR          |              441 |
| exporter |         1287 | ER_WARN_DEPRECATED_SYNTAX  |              147 |
| exporter |         1193 | ER_UNKNOWN_SYSTEM_VARIABLE |              147 |
+----------+--------------+----------------------------+------------------+
```

Look before you alert. In this lab, two of the biggest error sources are
harmless:

- the `exporter` account accumulates hundreds of parse and access errors
  of its own — statements some of its collectors try that this server
  rejects. Harmless to MySQL, but noise in any total;
- the `mysql` command-line client sends a probe statement, `select $$`, on
  every connection, and the server answers with error 1064. Every
  `./lab sql` you run adds one `root` parse error. (The `app` row above
comes from module 5's workload, which uses the same client.)

An alert on "statement errors > 0" would fire forever. Alert on a change
against the baseline, or on specific errors that mean harm
(`ER_LOCK_WAIT_TIMEOUT` 1205, `ER_LOCK_DEADLOCK` 1213,
`ER_CON_COUNT_ERROR` 1040).

### Saturation

Saturation is "work is waiting". For MySQL, the useful gauges:

```bash test
for q in \
  'mysql_global_status_threads_running' \
  'mysql_global_status_threads_connected / mysql_global_variables_max_connections' \
  '1 - rate(mysql_global_status_innodb_buffer_pool_reads[5m])
     / rate(mysql_global_status_innodb_buffer_pool_read_requests[5m])' \
  'mysql_global_status_innodb_row_lock_current_waits' \
  'mysql_info_schema_innodb_metrics_transaction_trx_rseg_history_len'
do
  echo "# $q" | tr -s ' \n' ' '; echo
  ./lab exec prometheus promtool query instant http://localhost:9090 "$q"
done
```

```text
# mysql_global_status_threads_running 
mysql_global_status_threads_running{instance="replica", job="mysql", role="replica"} => 3 @[1791889157.656]
mysql_global_status_threads_running{instance="primary", job="mysql", role="primary"} => 4 @[1791889157.656]
# mysql_global_status_threads_connected / mysql_global_variables_max_connections 
{instance="replica", job="mysql", role="replica"} => 0.01 @[1791889157.692]
{instance="primary", job="mysql", role="primary"} => 0.015 @[1791889157.692]
# 1 - rate(mysql_global_status_innodb_buffer_pool_reads[5m]) / rate(mysql_global_status_innodb_buffer_pool_read_requests[5m]) 
{instance="replica", job="mysql", role="replica"} => 1 @[1791889157.732]
{instance="primary", job="mysql", role="primary"} => 1 @[1791889157.732]
# mysql_global_status_innodb_row_lock_current_waits 
mysql_global_status_innodb_row_lock_current_waits{instance="replica", job="mysql", role="replica"} => 0 @[1791889157.765]
mysql_global_status_innodb_row_lock_current_waits{instance="primary", job="mysql", role="primary"} => 0 @[1791889157.765]
# mysql_info_schema_innodb_metrics_transaction_trx_rseg_history_len 
mysql_info_schema_innodb_metrics_transaction_trx_rseg_history_len{instance="replica", job="mysql", role="replica"} => 0 @[1791889157.797]
mysql_info_schema_innodb_metrics_transaction_trx_rseg_history_len{instance="primary", job="mysql", role="primary"} => 0 @[1791889157.797]
```

- **`Threads_running`** — sessions executing a statement right now,
  including those waiting for a lock. The single best saturation signal: a
  healthy OLTP server runs a handful; dozens sustained means work is
  queuing. Compare with the CPU count. **`Threads_connected`** is mostly
  idle pool connections and says little on its own — except near
  `max_connections`, where new connections fail with error 1040.
- **Buffer pool hit ratio** — the share of page requests served from
  memory. A ratio hides scale: 99.9% of 1 million requests a second is
  still 1 000 disk reads a second. Watch
  `rate(mysql_global_status_innodb_buffer_pool_reads[5m])` alongside it
  ([manual: buffer pool](https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool.html)).
- **Row-lock waits** — `Innodb_row_lock_current_waits` is a gauge of
  sessions waiting now; `Innodb_row_lock_waits` a counter of waits so far.
- **History list length** — undo records not yet purged. It grows while a
  long transaction holds an old read view, and every read of a hot row
  then has to walk further back through undo
  ([manual: purge configuration](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)).
  Steady growth over hours is a forgotten transaction somewhere.
- **Redo checkpoint age** — redo written but not yet checkpointed, as a
  share of `innodb_redo_log_capacity`. When it approaches the limit InnoDB
  must flush dirty pages synchronously and writes stall
  ([manual: redo log](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html)).
  The dashboard computes it from `Innodb_redo_log_current_lsn` and
  `Innodb_redo_log_checkpoint_lsn`.

## Replication: what lag really means

The exporter turns every numeric column of `SHOW REPLICA STATUS` into a
metric. On MySQL 8.4 the names follow the 8.4 column names:

```bash test
./lab exec prometheus promtool query instant \
  http://localhost:9090 '{__name__=~"mysql_slave_status_(seconds_behind_.*|.*_running)"}'
```

```text
mysql_slave_status_replica_io_running{instance="replica", job="mysql", master_host="primary", master_uuid="33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f", role="replica"} => 1 @[1791889157.835]
mysql_slave_status_replica_sql_running{instance="replica", job="mysql", master_host="primary", master_uuid="33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f", role="replica"} => 1 @[1791889157.835]
mysql_slave_status_seconds_behind_source{instance="replica", job="mysql", master_host="primary", master_uuid="33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f", role="replica"} => 0 @[1791889157.835]
```

Note the mixture: the metric prefix is still `mysql_slave_status_`, the
labels still say `master_host`, but the metric names come from the 8.4
columns — `seconds_behind_source`, `replica_io_running`,
`replica_sql_running`. Many published alert rules and dashboards use
`mysql_slave_status_seconds_behind_master` and `..._slave_io_running`.
Against 8.4 those names do not exist; a rule on them is valid PromQL,
passes `promtool`, and never fires. Check names against `/metrics` after
every MySQL or exporter upgrade.

### Why Seconds_Behind_Source misleads

`Seconds_Behind_Source` compares the replica's clock with the original
timestamp of the event the applier is executing
([manual: SHOW REPLICA STATUS](https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html)).
That definition has three blind spots:

1. **It is `NULL` when the applier is stopped** — exactly when the replica
   is falling further behind every second.
2. **It only sees what the receiver has fetched.** If the receiver (IO)
   thread is slow or stalled, the applier catches up with the relay log and
   reports 0. The manual says it plainly: the value is useful only for fast
   networks.
3. **It jumps.** An idle replica reads 0; the first event after a quiet
   period, or a long transaction, makes it leap.

See the first one, and what the exporter does with a `NULL`:

```bash test
./lab sql replica -e "STOP REPLICA SQL_THREAD"
./lab sql replica -e "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_(IO|SQL)_Running:|Seconds_Behind_Source'
sleep 10
echo "# lag series:"
./lab exec prometheus promtool query instant http://localhost:9090 \
  'mysql_slave_status_seconds_behind_source'
echo "# applier thread:"
./lab exec prometheus promtool query instant http://localhost:9090 \
  'mysql_slave_status_replica_sql_running'
sleep 20
echo "# alerts:"
./lab exec prometheus promtool query instant http://localhost:9090 \
  'ALERTS{alertname=~"MySQLReplication.*"}'
./lab sql replica -e "START REPLICA SQL_THREAD"
```

```text
           Replica_IO_Running: Yes
          Replica_SQL_Running: No
        Seconds_Behind_Source: NULL
# lag series:

# applier thread:
mysql_slave_status_replica_sql_running{instance="replica", job="mysql", master_host="primary", master_uuid="33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f", role="replica"} => 0 @[1791889168.051]
# alerts:
ALERTS{alertname="MySQLReplicationStopped", alertstate="firing", instance="replica", job="mysql", master_host="primary", master_uuid="33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f", role="replica", severity="page"} => 1 @[1791889188.097]
```

The lag series is simply gone: no sample, so `> 30` is never true and the
lag alert stays silent. The course's `MySQLReplicationStopped` rule watches
the thread flags instead: it was `pending` for its 15 s hold, then
`firing`. **Always alert on thread state and on lag; never on lag alone.**

### Better lag measurements

- **Heartbeat.** Write the current time into a table on the primary every
  second; on the replica, lag is `now() - that timestamp`. It measures the
  whole path — receive, relay, apply — and keeps rising when anything in
  it stops. [`pt-heartbeat`](https://docs.percona.com/percona-toolkit/pt-heartbeat.html)
  is the reference implementation, and `mysqld_exporter` can read its table
  (`--collect.heartbeat`).
- **GTID gap.** Transactions executed on the primary but not on the
  replica: `GTID_SUBTRACT(primary_gtid_executed, replica_gtid_executed)`.
  Exact, and independent of clocks.
- **Replication timestamps.** Since 8.0 every transaction carries its
  original commit time; `performance_schema.replication_applier_status_by_worker`
  exposes it per worker
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-applier-status-by-worker-table.html)),
  and the lab's exporter publishes it as
  `mysql_perf_schema_last_applied_transaction_original_commit_timestamp_seconds`.

A hand-made heartbeat and a GTID gap, with the receiver stopped — the case
where `Seconds_Behind_Source` is no help:

```bash test
./lab sql -e "CREATE SCHEMA lab;
              CREATE TABLE lab.heartbeat (id TINYINT PRIMARY KEY, ts TIMESTAMP(6) NOT NULL);
              INSERT INTO lab.heartbeat VALUES (1, NOW(6));"
sleep 2
./lab sql replica -e "STOP REPLICA IO_THREAD"
for _ in 1 2 3 4 5 6; do
  ./lab sql -e "UPDATE lab.heartbeat SET ts = NOW(6) WHERE id = 1"
  sleep 1
done
primary_gtids="$(./lab sql -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
./lab sql replica -e "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_(IO|SQL)_Running:|Seconds_Behind_Source'
./lab sql replica --table -e "
  SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, ts, NOW(6)) / 1e6, 1) AS heartbeat_age_s
  FROM lab.heartbeat;
  SELECT GTID_SUBTRACT('$primary_gtids', @@GLOBAL.gtid_executed) AS missing_on_replica;"
./lab sql replica -e "START REPLICA IO_THREAD"
./lab sql -e "DROP SCHEMA lab"
```

```text
           Replica_IO_Running: No
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: NULL
+-----------------+
| heartbeat_age_s |
+-----------------+
|             8.9 |
+-----------------+
+--------------------------------------------+
| missing_on_replica                         |
+--------------------------------------------+
| 33a7ab7c-c6f3-11f1-a2ca-c2d8fddd337f:78-83 |
+--------------------------------------------+
```

The replica is missing six transactions and its newest data is nine
seconds old, while `Seconds_Behind_Source` says `NULL`. (A real heartbeat
writes every second, forever, so the age is lag plus at most one second.)

## Prometheus rules and alerts

Rule files are YAML, loaded by `rule_files` in `prometheus.yml`. The lab
loads the course's rules and anything you put in `rules.d/`:

```yaml
rule_files:
  - /etc/prometheus/dbre/alerts.yml
  - /etc/prometheus/dbre/rules.d/*.yml
```

An alerting rule
([Prometheus docs](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)):

```yaml
- alert: MySQLReplicationStopped
  expr: mysql_slave_status_replica_io_running == 0 or mysql_slave_status_replica_sql_running == 0
  for: 15s
  labels: { severity: page }
  annotations:
    summary: "A replication thread is stopped on {{ $labels.instance }}"
    runbook_url: "https://github.com/MoiToiTech/dbre-academy/blob/main/courses/mysql-production-dba/08-monitoring-observability/README.md#runbook-replication"
```

- `expr` is a PromQL expression; every series it returns is an active
  alert, with that series' labels.
- `for` holds the alert in `pending` until the expression has been true
  for that long, then it becomes `firing`. It filters one-scrape blips.
  `keep_firing_for` does the reverse, for flapping recoveries.
- `labels` are added to the alert — `severity` is what routing in
  Alertmanager (not part of this lab) uses to decide page or ticket.
- `annotations` are for the human: what is wrong, and where the runbook is.

Validate syntax with `promtool check rules`, and *behaviour* with
`promtool test rules`: a unit test feeds synthetic series to the rules and
asserts which alerts fire when
([promtool docs](https://prometheus.io/docs/prometheus/latest/command-line/promtool/)).
The lab ships tests for the course rules in
[`tests/alerts_test.yml`](../../../labs/observability/prometheus/tests/alerts_test.yml),
including the "lag series vanishes" case above:

```bash test
./lab exec prometheus promtool check rules /etc/prometheus/dbre/alerts.yml
./lab exec prometheus promtool test rules /etc/prometheus/dbre/tests/alerts_test.yml
```

```text
Checking /etc/prometheus/dbre/alerts.yml
  SUCCESS: 6 rules found

  SUCCESS
```

After editing a rule file, reload Prometheus (the lab runs it with
`--web.enable-lifecycle`) — a failed reload keeps the old rules and says
why:

```bash test
curl -s -X POST "http://127.0.0.1:${DBRE_PROMETHEUS_PORT:-19090}/-/reload" && echo reloaded
```

```text
reloaded
```

## Designing alerts that people trust

An alert interrupts a person. Each one should pass four tests
([Prometheus: alerting practices](https://prometheus.io/docs/practices/alerting/),
[Google SRE book: monitoring](https://sre.google/sre-book/monitoring-distributed-systems/)):

1. **Symptom over cause.** Page on what users feel or are about to feel —
   the server is unreachable, replication has stopped, sessions are piling
   up, connections are nearly exhausted. Causes (a high history list, a
   low hit ratio) belong on dashboards and in tickets.
2. **Actionable.** Someone woken at 03:00 can do something about it now,
   and the runbook link says what. If the honest answer is "wait and see",
   it is not a page.
3. **Sustained.** A `for:` long enough to skip noise — minutes in
   production; seconds in this lab so that exercises finish.
4. **Severity matches urgency.** `page` interrupts; `warn` (or `ticket`)
   waits for working hours.

Two failure modes to design out:

- **Silence that looks like health.** A rule on a metric that is missing —
  wrong name, `NULL` value, dead exporter — never fires. Cover the
  monitoring itself (`up == 0`, the course's `MySQLExporterDown`), and use
  `absent()` for series that must exist.
- **Alerts nobody acts on.** Every alert that fires without action trains
  people to ignore the next one. Delete or demote it.

<!-- founder-review: a first-hand story about an alert that never fired, or
one that fired so often it was ignored, would make this section stick -->

## Dashboards

The lab provisions one dashboard, **DBRE Lab — MySQL** (uid `dbre-mysql`),
from [`grafana/dashboards/mysql.json`](../../../labs/observability/grafana/dashboards/mysql.json).
It is laid out in the order you diagnose:

| Row | Panels | Question it answers |
|---|---|---|
| Availability | `mysql_up`, scrape `up`, replication threads, uptime | Is it there at all? |
| Traffic and errors | QPS, statements by type, slow queries/s, connection errors | Is the workload normal? |
| Saturation | threads running vs connected, connections %, row-lock waits, buffer pool, history list, redo, temp tables | Is work queuing, and on what? |
| Replication | `Seconds_Behind_Source`, IO/SQL thread state | Is the replica current — and *running*? |

Every panel has a description (hover the ⓘ) saying what the metric is and
how it misleads. Firing alerts are drawn as annotations on every graph.
Check that Grafana loaded it:

```bash test
curl -s "http://127.0.0.1:${DBRE_GRAFANA_PORT:-13000}/api/dashboards/uid/dbre-mysql" \
  | grep -m1 -o '"title":"DBRE Lab[^"]*"'
```

```text
"title":"DBRE Lab — MySQL"
```

Dashboards are for diagnosis, alerts for detection. A good dashboard lets
the person who was paged answer "where?" in a minute: start top-left, go
down until something looks different from the last hour.

## Runbooks

The course's alerts link here. A runbook is short: what the alert means,
what to check first, what to do, when to escalate.

### Runbook: MySQL down

*Alerts: `MySQLDown`, `MySQLExporterDown`.* Check which one: if the
exporter is down, MySQL may be fine but you are blind. `./lab status`;
`docker logs` of the exporter or `./lab logs primary`. If mysqld is down,
read the error log before restarting — a crash loop on start-up is often
the disk or the redo log, and a restart destroys the evidence.

### Runbook: replication

*Alerts: `MySQLReplicationStopped`, `MySQLReplicationLag`.* On the replica,
`SHOW REPLICA STATUS\G`: which thread stopped, `Last_IO_Error`,
`Last_SQL_Error`, and `performance_schema.replication_applier_status_by_worker`
for the failing transaction. Lag with both threads running: is the
primary's write rate up, or is one long transaction being applied? Module 7
covers the fixes. Never skip a transaction (with GTIDs: commit an empty
transaction in its place) without knowing what it contained.

### Runbook: connections

*Alert: `MySQLConnectionsNearLimit`.* `SELECT user, host, COUNT(*) FROM
performance_schema.processlist GROUP BY 1, 2 ORDER BY 3 DESC`. Usually one
application's pool grew or connections leak. Raising `max_connections`
buys minutes and costs memory per connection; find the client first.

### Runbook: threads running

*Alerts: `MySQLRowLockWaits`, and the saturation alert you write in the
exercise.* Many sessions are inside the server and not finishing. In
order: `sys.innodb_lock_waits` (one blocker, many waiters?), long
transactions in `information_schema.innodb_trx` ordered by
`trx_started`, then `sys.statement_analysis` for a new expensive
statement. A blocker idle in an open transaction is ended with
`KILL <processlist id>` — the connection, so its transaction rolls back
([manual: KILL](https://dev.mysql.com/doc/refman/8.4/en/kill.html)).
`KILL QUERY` only stops the running statement: the connection, its open
transaction and the row locks it holds stay in place.

## Common mistakes and troubleshooting

- **Old metric names.** `..._seconds_behind_master` and `..._slave_io_running`
  do not exist against MySQL 8.4. A rule on them is silent forever.
- **Lag-only replication alerts.** `Seconds_Behind_Source` is `NULL` when
  the applier stops; the series vanishes and the alert cannot fire.
- **`rate()` on a gauge, or a gauge used as a counter.** `rate()` of
  `Threads_running` is meaningless; a raw `Questions` value is a number
  since start-up.
- **Alerting on causes.** A buffer pool hit ratio below 99% pages someone
  for a server that is serving users fine.
- **No `for:`.** One unlucky scrape pages someone.
- **A broken rule file.** Prometheus refuses the reload and keeps the old
  rules — and if it restarts with the broken file, it does not start at
  all. Run `promtool check rules` before every reload.
- **Monitoring with a privileged account.** The exporter needs `PROCESS`,
  `REPLICATION CLIENT` and `SELECT`, with a connection cap.

## Further reading

- [mysqld_exporter README](https://github.com/prometheus/mysqld_exporter):
  collectors, flags and the recommended grants.
- Prometheus docs:
  [alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/),
  [recording rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/),
  [alerting practices](https://prometheus.io/docs/practices/alerting/),
  [promtool](https://prometheus.io/docs/prometheus/latest/command-line/promtool/),
  [management API (reload)](https://prometheus.io/docs/prometheus/latest/management_api/).
- MySQL 8.4 Reference Manual:
  [SHOW REPLICA STATUS](https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html),
  [Checking replication status](https://dev.mysql.com/doc/refman/8.4/en/replication-administration-status.html),
  [Server status variables](https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html),
  [Statement histogram summary tables](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-histogram-summary-tables.html).
- [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/).
- Google SRE book,
  [Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/).

## Next

Do the [exercise](exercise.md): sessions are piling up, nothing alerts, and
you write the alert. Then the [quiz](quiz.md). Module 9 puts monitoring to
work in incident response.
