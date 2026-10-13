# Exercise 8 — Sessions pile up and nothing alerts

`time: ~40 min` · `scenario: 08-saturation-alert` · needs `./lab up --observability`

Checkout requests are timing out. The application team says "the database
is hanging". Prometheus is scraping the primary, the course's alert rules
are loaded — and nothing has fired.

Your job:

1. Find what is saturated, using metrics first.
2. Confirm the cause inside MySQL.
3. Write the alert that should have paged someone, and prove it fires.

This scenario needs Prometheus. Check it is running:

```bash test
curl -sf "http://127.0.0.1:${DBRE_PROMETHEUS_PORT:-19090}/-/ready" \
  || { echo "Prometheus not reachable: run ./lab up --observability"; exit 1; }
```

## Start the scenario

```bash test
./lab scenario setup 08-saturation-alert
```

```text
==> Application sessions are piling up on the primary (container dbre-08-pileup).
Checkout requests time out, yet no alert has fired. Use Grafana
(http://127.0.0.1:13000, dashboard 'DBRE Lab — MySQL') or Prometheus
(http://127.0.0.1:19090) to see what is saturated, then write an
alert rule in observability/prometheus/rules.d/saturation.yml that fires on it.
Then: ./lab check 08-saturation-alert
```

The fault runs in its own container until you reset the scenario. It does
not change any data.

## Part 1 — Find it from the metrics

Open the dashboard: Grafana → *Dashboards* → *DBRE Lab* → *DBRE Lab —
MySQL*. Before reading on, write down which panels look different from the
quiet lab you saw in the lesson, and which do not.

Then put numbers on it. Give Prometheus 30 seconds to scrape a few times:

```bash test
sleep 30
for q in \
  'mysql_global_status_threads_running' \
  'mysql_global_status_innodb_row_lock_current_waits' \
  'rate(mysql_global_status_innodb_row_lock_waits[1m])' \
  'rate(mysql_global_status_questions[1m])' \
  'ALERTS'
do
  echo "# $q"
  ./lab exec prometheus promtool query instant http://localhost:9090 "$q"
done
```

```text
# mysql_global_status_threads_running
mysql_global_status_threads_running{instance="replica", job="mysql", role="replica"} => 3 @[1791889254.879]
mysql_global_status_threads_running{instance="primary", job="mysql", role="primary"} => 20 @[1791889254.879]
# mysql_global_status_innodb_row_lock_current_waits
mysql_global_status_innodb_row_lock_current_waits{instance="replica", job="mysql", role="replica"} => 0 @[1791889254.969]
mysql_global_status_innodb_row_lock_current_waits{instance="primary", job="mysql", role="primary"} => 16 @[1791889254.969]
# rate(mysql_global_status_innodb_row_lock_waits[1m])
{instance="replica", job="mysql", role="replica"} => 0 @[1791889255.001]
{instance="primary", job="mysql", role="primary"} => 0.539714055407068 @[1791889255.001]
# rate(mysql_global_status_questions[1m])
{instance="replica", job="mysql", role="replica"} => 5.10890513072252 @[1791889255.036]
{instance="primary", job="mysql", role="primary"} => 7.2546773577701416 @[1791889255.036]
# ALERTS

```

Read it like an on-call engineer:

- **Saturation:** 20 threads running on the primary, against 3–4 when
  idle. Sixteen sessions are waiting for a row lock *right now*.
- **Throughput:** almost nothing is getting done — a handful of
  statements a second. High `Threads_running` with *low* throughput is
  the signature of waiting, not of load.
- **Why the course's `MySQLRowLockWaits` is silent:** it alerts on the
  *rate of new* lock waits (> 1/s). Each waiter here sits for the full
  `innodb_lock_wait_timeout` (20 s), so new waits start only ~0.5 times a
  second. The worse each wait is, the lower that rate. A rate alert is the
  wrong shape for a pile-up; a gauge of how much is waiting *now* is the
  right one.
- **`ALERTS` is empty.** That is the problem you are here to fix.

## Part 2 — Confirm it inside MySQL

Metrics told you *what*; MySQL tells you *who*:

```sql test
SELECT COUNT(*) AS wait_edges, COUNT(DISTINCT blocking_pid) AS blocking_pids
FROM sys.innodb_lock_waits;
```

```text
+------------+---------------+
| wait_edges | blocking_pids |
+------------+---------------+
|        136 |            16 |
+------------+---------------+
```

Sixteen "blockers"? Waiters queued on the same row block each other in
InnoDB's lock queue, so `sys.innodb_lock_waits` lists every pair. The one
that matters is the **root blocker** — blocking others while waiting for
nobody:

```sql test
SELECT DISTINCT w.blocking_pid AS root_blocker, w.blocking_query,
       w.sql_kill_blocking_connection
FROM sys.innodb_lock_waits w
WHERE w.blocking_pid NOT IN (SELECT waiting_pid FROM sys.innodb_lock_waits);
```

```text
+--------------+-----------------------------------+------------------------------+
| root_blocker | blocking_query                    | sql_kill_blocking_connection |
+--------------+-----------------------------------+------------------------------+
|         1332 | DO SLEEP(86400), 'dbre-08-pileup' | KILL 1332                    |
+--------------+-----------------------------------+------------------------------+
```

One `app` session locked an inventory row and then stalled inside its
transaction — in real life, a request handler waiting on a slow payment
API before `COMMIT`. Leave it running for now: an alert can only be tested
against a live condition.

## Part 3 — Write the alert

Create `labs/observability/prometheus/rules.d/saturation.yml` (from the
`labs/` directory: `observability/prometheus/rules.d/saturation.yml`).
Prometheus already loads every `*.yml` in that directory; the directory is
mounted into the container, so you edit on your machine.

The format, with an example rule for a *different* condition:

```yaml
groups:
  - name: my-mysql-rules
    rules:
      - alert: MySQLConnectionsNearLimit
        expr: mysql_global_status_threads_connected / mysql_global_variables_max_connections > 0.8
        for: 30s
        labels:
          severity: warn
        annotations:
          summary: "{{ $labels.instance }} uses over 80% of max_connections"
          runbook_url: "https://github.com/MoiToiTech/dbre-academy/blob/main/courses/mysql-production-dba/08-monitoring-observability/README.md#runbook-connections"
```

Your rule must:

- fire on the saturation you found in Part 1 — use
  `mysql_global_status_threads_running` or
  `mysql_global_status_innodb_row_lock_current_waits`;
- fire for `instance="primary"` now, and stay quiet for the idle replica
  (so pick a threshold well above an idle server's value);
- have a `for:` hold — 15 s to 60 s in the lab (minutes in production);
- carry a `severity` label and `summary` and `runbook_url` annotations.
  The lesson's [runbook for threads running](README.md#runbook-threads-running)
  is the right link.

Try your expression in the Prometheus UI (*Graph* tab) first. Then
validate and load it:

```bash
./lab exec prometheus promtool check rules /etc/prometheus/dbre/rules.d/saturation.yml
curl -s -X POST "http://127.0.0.1:${DBRE_PROMETHEUS_PORT:-19090}/-/reload"
```

In the Prometheus UI, *Alerts* shows your rule go *pending*, then
*firing* once the `for:` time has passed. Then run the check:

```bash
./lab check 08-saturation-alert
```

The check validates the file with `promtool`, checks the alert design
items above, reloads Prometheus, waits up to two minutes for your alert to
fire for the primary, and confirms it is not firing for the replica.
Before you have written the file, it fails:

```bash test expect-error
./lab check 08-saturation-alert
```

```text
Checking 08-saturation-alert
  PASS the session pile-up is still in progress (alerts need a live condition)
  FAIL no rule file at observability/prometheus/rules.d/saturation.yml
       hint: create it with one alerting rule — the exercise shows the file format
1 check(s) failed.
```

A reference rule is in `labs/scenarios/08-saturation-alert/solve.sh`.

<details>
<summary>Discussion: which metric, which threshold?</summary>

Both accepted metrics work here; they answer slightly different questions.

- `mysql_global_status_threads_running > 10` — "work is queuing inside
  the server", whatever the reason: locks, a CPU-bound query storm, I/O
  stalls. Broad, symptom-level, a good page. The threshold should sit
  above your busiest normal peak; on real hardware it is usually tied to
  the CPU count.
- `mysql_global_status_innodb_row_lock_current_waits > 5` — "sessions are
  queuing on row locks". Narrower, and closer to the cause; often a
  `warn` alongside the broader page.

Avoid `rate(...row_lock_waits...)` for this: as Part 1 showed, it falls as
the pile-up gets worse.

</details>

## Part 4 — Resolve the incident (optional)

With the alert firing, end the stall the way you would in production:

1. Find the root blocker (Part 2).
2. `KILL <id>` — the connection, not `KILL QUERY`. Killing only the
   statement would leave the transaction open and the row locked.
3. Watch `Threads_running` fall on the dashboard and your alert resolve
   within one evaluation.

In this lab the pile-up container will start the stall again only if you
re-run setup.

## Stretch

- Write a `promtool test rules` unit test for your rule, modelled on
  `labs/observability/prometheus/tests/alerts_test.yml`: a series that
  rises above your threshold for longer than `for:`, and one that spikes
  for a single scrape and must *not* fire.
- Your alert fires on the replica too if someone runs a report there.
  Should it? Would you route a replica's saturation alert differently?

## Clean up

```bash test
./lab scenario reset 08-saturation-alert
```

Reset stops the pile-up, kills any of its sessions still in the server,
deletes `rules.d/saturation.yml` and reloads Prometheus. Copy your rule
somewhere else first if you want to keep it.
