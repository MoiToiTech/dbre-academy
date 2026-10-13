# Module 5 — Performance diagnostics and slow queries

`time: ~75 min` · `lab: ./lab scenario setup 05-slow-query` · `level: fundamentals`

"The database is slow" is a report about a symptom, not a diagnosis. The
fastest way from that report to a fix is to ask the server where its time
goes — which statements, how often, how much work each one does — before
touching a single configuration variable. MySQL records this for you, in
the slow query log and in the Performance Schema. This module teaches you to
read both, to recognise the predicates that stop an index being used, and
to fix them on the database side when you cannot change the application.

## Learning objectives

By the end of this module you can:

- apply a workload-first method (USE and RED) to a MySQL server;
- configure the slow query log deliberately, and say what each setting
  costs and hides;
- rank statements by total time with `events_statements_summary_by_digest`
  and the `sys` schema, and explain why total time beats average time;
- tell `SHOW PROCESSLIST` from `performance_schema.processlist` and
  `threads`, and know when a snapshot is the wrong tool;
- recognise non-sargable predicates — functions on columns, implicit type
  conversion, leading wildcards — and choose between a database-side fix
  (functional index, generated column) and an application-side fix.

## Prerequisites

- Module 4: reading `EXPLAIN`, access types, composite indexes.
- The lab running: `./lab up`. Commands run from the `labs/` directory.

## A method: start from the workload

Two checklists keep an investigation honest.

- **USE** ([Brendan Gregg](https://www.brendangregg.com/usemethod.html)) —
  for every *resource*: **U**tilisation, **S**aturation, **E**rrors. For a
  MySQL host the resources are CPU, disk, memory (the buffer pool),
  connections (`max_connections`) and locks.
- **RED** ([Tom Wilkie](https://grafana.com/blog/2018/08/02/the-red-method-how-to-instrument-your-services/)) —
  for every *service*: **R**ate, **E**rrors, **D**uration. For MySQL the
  service is "run my statements", and the unit is a normalised statement.

A database is both a service and a pile of resources, so use both — in
this order:

1. **What changed?** Deploys, traffic, data volume, a new report.
2. **RED on the workload.** Which statements consume the server's time —
   `calls × average latency` — and did their rate, errors or latency move?
3. **USE on the resources** those statements touch. Saturation of CPU, I/O
   or locks explains *why* the top statements are slow.
4. **Only then configuration.** A variable change is a fix for a measured
   resource problem, not a first move.

The trap is step 4 first: "raise `innodb_buffer_pool_size`" or "add
`innodb_io_capacity`" because a checklist says so. If one statement scans
200 000 rows twice a second, no setting fixes that; an index does.

<!-- founder-review: a short real story about tuning config while the real
cause was one statement would land this point -->

Module 8 turns these signals into dashboards and alerts. This module is
about the statement level.

## The slow query log

The slow query log records statements that ran longer than
`long_query_time` seconds, after they finish
([manual: The Slow Query Log](https://dev.mysql.com/doc/refman/8.4/en/slow-query-log.html)).
The lab enables it from the start:

```sql test
SELECT @@slow_query_log, @@slow_query_log_file, @@long_query_time,
       @@log_slow_extra, @@log_queries_not_using_indexes,
       @@min_examined_row_limit;
```

```text
+------------------+-------------------------+-------------------+------------------+---------------------------------+--------------------------+
| @@slow_query_log | @@slow_query_log_file   | @@long_query_time | @@log_slow_extra | @@log_queries_not_using_indexes | @@min_examined_row_limit |
+------------------+-------------------------+-------------------+------------------+---------------------------------+--------------------------+
|                1 | /var/lib/mysql/slow.log |          1.000000 |                0 |                               0 |                        0 |
+------------------+-------------------------+-------------------+------------------+---------------------------------+--------------------------+
```

The settings that matter:

| Variable | What it does | Watch out for |
|---|---|---|
| `long_query_time` | Threshold in seconds, microsecond resolution. | Read at connect time: a `SET GLOBAL` only affects new sessions. |
| `log_slow_extra` | Adds handler counters, bytes, errno, start/end time. | Global only. Worth turning on; the format change breaks old parsers. |
| `log_queries_not_using_indexes` | Also logs statements that use no index, however fast. | Noisy: logs every scan of a 10-row lookup table. Throttle with `log_throttle_queries_not_using_indexes`. |
| `min_examined_row_limit` | Skips statements that examined fewer rows. | Hides fast-but-frequent statements on purpose. |

`long_query_time` is also a session variable, which gives you a precise
tool: log *everything* from one session, without flooding the log with the
whole server's traffic.

```bash test
./lab sql -e "SET GLOBAL log_slow_extra = ON"
./lab sql -e "SET SESSION long_query_time = 0;
              SELECT COUNT(*) FROM shop.products WHERE name LIKE '%pump%';"
./lab exec primary grep -B 4 "LIKE '%pump%'" /var/lib/mysql/slow.log | tail -n 5
./lab sql -e "SET GLOBAL log_slow_extra = OFF"
```

```text
# Time: 2026-10-13T10:47:47.691704Z
# User@Host: root[root] @ localhost []  Id:   151
# Query_time: 0.000527  Lock_time: 0.000001 Rows_sent: 1  Rows_examined: 1000 Thread_id: 151
Errno: 0 Killed: 0 Bytes_received: 80 Bytes_sent: 58 Read_first: 1 Read_last: 0 Read_key: 1
Read_next: 0 Read_prev: 0 Read_rnd: 0 Read_rnd_next: 1001 Sort_merge_passes: 0 ...
SET timestamp=1791888467;
SELECT COUNT(*) FROM shop.products WHERE name LIKE '%pump%';
```

The `# Query_time` line is one long line in the file, wrapped here; the
`COUNT(*)` result printed before it is left out. Read it as evidence:
`Rows_sent: 1` against `Rows_examined: 1000` and `Read_rnd_next: 1001` (the
handler call that reads the next row of a full scan) — a whole table read
to return one number. Timing values differ on
your machine; row counts do not.

Two things the log does not tell you on its own:

- **Blocked is not expensive.** A statement that waited 20 s for a row lock
  and examined no rows is logged with `Query_time` and `Lock_time` both
  near 20 s. The slow log mixes statements that *did* a lot of work with
  statements that *waited* for someone else's (module 3).
- **Fast and frequent is invisible.** At `long_query_time = 1`, a 15 ms
  statement that runs 100 times a second never appears, yet it costs the
  server 1.5 s of work every second. The exercise for this module is built
  on exactly that.

### mysqldumpslow

`mysqldumpslow` groups log entries by normalising literals to `N` and
`'S'` ([manual](https://dev.mysql.com/doc/refman/8.4/en/mysqldumpslow.html)).
`-s t` sorts by total query time, `-t N` keeps the top N, `-g` greps:

```bash test
./lab exec primary mysqldumpslow -s t -g pump /var/lib/mysql/slow.log
```

```text
Count: 3  Time=0.00s (0s)  Lock=0.00s (0s)  Rows=1.0 (3), root[root]@localhost
  SELECT COUNT(*) FROM shop.products WHERE name LIKE 'S'


Reading mysql slow query log from /var/lib/mysql/slow.log
```

Without `-g`, a freshly started lab shows the dataset load itself — the
statements that generated the shop data took around two seconds each:

```text
$ ./lab exec primary mysqldumpslow -s t -t 2 /var/lib/mysql/slow.log
Reading mysql slow query log from /var/lib/mysql/slow.log
Count: 1  Time=2.00s (2s)  Lock=0.00s (0s)  Rows=0.0 (0), root[root]@localhost
  UPDATE order_items i JOIN products p ON p.id = i.product_id
  SET i.price_cents = p.price_cents

Count: 1  Time=1.94s (1s)  Lock=0.00s (0s)  Rows=0.0 (0), root[root]@localhost
  INSERT INTO order_items (order_id, line_no, product_id, quantity, price_cents)
  SELECT o.id, l.n,
  ...
```

Two quirks of the 8.4 `mysqldumpslow`:

- It subtracts lock time from query time unless you pass `-l`, so
  lock-blocked statements sort to the bottom — useful or misleading,
  depending on the question.
- If `-t N` asks for more entries than there are distinct statements, it
  prints them and then exits with `Died at /usr/bin/mysqldumpslow line
  163` (status 255). Harmless, but it breaks scripts; lower `-t`.

For larger logs, `pt-query-digest` from the free
[Percona Toolkit](https://docs.percona.com/percona-toolkit/pt-query-digest.html)
produces a richer report (percentiles, per-query profiles). It is optional;
nothing in this course depends on it.

## Statement digests in the Performance Schema

The slow log samples by threshold. The Performance Schema counts
*everything*: every statement is normalised to a **digest** — literals
replaced by `?`, whitespace and case folded — and its counters are added to
one row per digest in `events_statements_summary_by_digest`
([manual: statement digests](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-digests.html),
[summary tables](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-summary-tables.html)).

Generate a small, known workload — 200 indexed lookups, 200 searches with
a leading wildcard, and 10 runs of a report:

```bash test
./lab sql -e "TRUNCATE TABLE performance_schema.events_statements_summary_by_digest"
for i in $(seq 1 200); do
  echo "SELECT id, status FROM shop.orders WHERE customer_id = $((i * 37 % 20000 + 1))
        ORDER BY id DESC LIMIT 10;"
  echo "SELECT COUNT(*) FROM shop.products WHERE name LIKE '%pump%';"
  if [ $((i % 20)) -eq 0 ]; then
    echo "SELECT customer_id, SUM(total_cents) FROM shop.orders
          GROUP BY customer_id ORDER BY 2 DESC LIMIT 5;"
  fi
done | ./lab sql >/dev/null
```

`TRUNCATE` resets the statistics — fine in a lab. On a shared production
server other people rely on those counters: take a snapshot into a table
and diff two snapshots instead.

Now rank by total time:

```sql test
SELECT LEFT(DIGEST_TEXT, 48)                 AS digest_text,
       COUNT_STAR                            AS calls,
       ROUND(SUM_TIMER_WAIT / 1e12, 3)       AS total_s,
       ROUND(AVG_TIMER_WAIT / 1e9, 2)        AS avg_ms,
       ROUND(SUM_ROWS_EXAMINED / COUNT_STAR) AS exam_per_call,
       SUM_NO_INDEX_USED                     AS no_index
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%`shop`%'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 5;
```

```text
+--------------------------------------------------+-------+---------+--------+---------------+----------+
| digest_text                                      | calls | total_s | avg_ms | exam_per_call | no_index |
+--------------------------------------------------+-------+---------+--------+---------------+----------+
| SELECT `customer_id` , SUM ( `total_cents` ) FRO |    10 |   0.859 |  85.86 |        200005 |        0 |
| SELECT COUNT ( * ) FROM `shop` . `products` WHER |   200 |   0.022 |   0.11 |          1000 |      200 |
| SELECT `id` , STATUS FROM `shop` . `orders` WHER |   200 |   0.009 |   0.05 |             8 |        0 |
+--------------------------------------------------+-------+---------+--------+---------------+----------+
```

What to read from it:

- **Units.** `*_TIMER_WAIT` columns are in **picoseconds**
  ([manual: event timing](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-timing.html)).
  Divide by 10¹² for seconds, 10⁹ for milliseconds — or use
  `format_pico_time()`.
- **Total time ranks the work.** The report ran 10 times and still cost
  roughly 40 times more than 200 product searches. Your timings will differ;
  the ranking and the row counts will not.
- **`exam_per_call` is the efficiency signal.** 200 005 rows examined to
  return 5. `no_index = 0` does not mean "efficient": this statement walks
  the whole of `idx_orders_customer` (a full *index* scan), which the
  "no index used" counter does not count.
- **Digests group shapes, not values.** All 200 lookups, with 200
  different `customer_id`s, are one row. That is what makes "which query
  shape costs the most" answerable.

The same table keeps one real example of each shape and latency
percentiles:

```sql test
SELECT DIGEST_TEXT, QUERY_SAMPLE_TEXT,
       format_pico_time(QUANTILE_95)    AS p95,
       format_pico_time(MAX_TIMER_WAIT) AS max
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST_TEXT LIKE '%`shop`%'
ORDER BY SUM_TIMER_WAIT DESC LIMIT 1\G
```

```text
*************************** 1. row ***************************
      DIGEST_TEXT: SELECT `customer_id` , SUM ( `total_cents` ) FROM `shop` . `orders` GROUP BY `customer_id` ORDER BY ? DESC LIMIT ?
QUERY_SAMPLE_TEXT: SELECT customer_id, SUM(total_cents) FROM shop.orders
          GROUP BY customer_id ORDER BY 2 DESC LIMIT 5
              p95: 120.23 ms
              max: 115.65 ms
```

A p95 above the maximum is not a bug: quantiles come from a histogram and
report the upper bound of the bucket they fall in
([manual: statement histograms](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-histogram-summary-tables.html)).
Treat them as "no worse than", to within a few per cent.

Digest storage is bounded (`performance_schema_digests_size`); when it is
full, new shapes are counted in a catch-all row with a `NULL` digest. If
that row is large, your statistics are incomplete.

## The sys schema: the same data, readable

The [`sys` schema](https://dev.mysql.com/doc/refman/8.4/en/sys-schema.html)
wraps the Performance Schema in views with formatted units. Each view has
an `x$` twin with raw numbers — use the `x$` view whenever you filter or
compute, because the formatted `query` column is truncated:

```sql test
SELECT sys.format_statement(query) AS query, exec_count,
       format_pico_time(total_latency) AS total_latency,
       format_pico_time(avg_latency)   AS avg_latency, rows_examined_avg
FROM sys.`x$statement_analysis`
WHERE query LIKE '%`shop`%'
LIMIT 5;
```

```text
+-------------------------------------------------------------------+------------+---------------+-------------+-------------------+
| query                                                             | exec_count | total_latency | avg_latency | rows_examined_avg |
+-------------------------------------------------------------------+------------+---------------+-------------+-------------------+
| SELECT `customer_id` , SUM ( ` ... er_id` ORDER BY ? DESC LIMIT ? |         10 | 858.61 ms     | 85.86 ms    |            200005 |
| SELECT COUNT ( * ) FROM `shop` . `products` WHERE NAME LIKE ?     |        200 | 21.91 ms      | 109.53 us   |              1000 |
| SELECT `id` , STATUS FROM `sho ... = ? ORDER BY `id` DESC LIMIT ? |        200 | 9.03 ms       | 45.14 us    |                 8 |
+-------------------------------------------------------------------+------------+---------------+-------------+-------------------+
```

The views you will use most:

| View | Answers |
|---|---|
| [`statement_analysis`](https://dev.mysql.com/doc/refman/8.4/en/sys-statement-analysis.html) | Which statement shapes cost the most, sorted by total latency. |
| [`statements_with_full_table_scans`](https://dev.mysql.com/doc/refman/8.4/en/sys-statements-with-full-table-scans.html) | Which shapes read whole tables without an index. |
| [`statements_with_runtimes_in_95th_percentile`](https://dev.mysql.com/doc/refman/8.4/en/sys-statements-with-runtimes-in-95th-percentile.html) | Which shapes are among the slowest 5% on average. |
| [`user_summary`](https://dev.mysql.com/doc/refman/8.4/en/sys-user-summary.html), [`host_summary`](https://dev.mysql.com/doc/refman/8.4/en/sys-host-summary.html) | Which account or client host the load comes from. |

```sql test
SELECT sys.format_statement(query) AS query, exec_count,
       no_index_used_count, rows_examined_avg
FROM sys.`x$statements_with_full_table_scans`
WHERE query LIKE '%`shop`%';

SELECT user, statements, statement_latency, table_scans, current_connections
FROM sys.user_summary;
```

```text
+---------------------------------------------------------------+------------+---------------------+-------------------+
| query                                                         | exec_count | no_index_used_count | rows_examined_avg |
+---------------------------------------------------------------+------------+---------------------+-------------------+
| SELECT COUNT ( * ) FROM `shop` . `products` WHERE NAME LIKE ? |        200 |                 200 |              1000 |
+---------------------------------------------------------------+------------+---------------------+-------------------+
+-----------------+------------+-------------------+-------------+---------------------+
| user            | statements | statement_latency | table_scans | current_connections |
+-----------------+------------+-------------------+-------------+---------------------+
| root            |       3232 | 21.47 s           |        1264 |                   1 |
| exporter        |        650 | 282.38 ms         |         208 |                   0 |
| repl            |          9 | 387.50 us         |           0 |                   1 |
| background      |          0 |   0 ps            |           0 |                  41 |
| event_scheduler |          0 |   0 ps            |           0 |                   1 |
+-----------------+------------+-------------------+-------------+---------------------+
```

The full-scan view lists the wildcard search but not the 200 005-row
report, for the reason above: a full *index* scan counts as "index used".
`user_summary` answers "is it the application, the monitoring, or a person
with a console?" — the `exporter` row is the Prometheus exporter from
module 8 and is only there if you started the lab with `--observability`.

## What is running right now

Digests tell you what happened. For what is happening, there are three
views of the same thread list:

| Source | Notes |
|---|---|
| `SHOW PROCESSLIST` | Classic. Holds a global mutex while it walks the thread list. |
| `performance_schema.processlist` | Same columns, no global mutex ([manual](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-processlist-table.html)). |
| `performance_schema.threads` | Every thread, background ones too, with `THREAD_ID` to join to other Performance Schema tables. |

`INFORMATION_SCHEMA.PROCESSLIST` is deprecated in 8.4. Setting
`performance_schema_show_processlist = ON` makes `SHOW PROCESSLIST` use the
Performance Schema implementation.

```sql test
SELECT ID, USER, HOST, COMMAND, TIME, STATE, LEFT(INFO, 40) AS info
FROM performance_schema.processlist
WHERE COMMAND <> 'Daemon'
ORDER BY TIME DESC;
```

```text
+-----+------+---------------------+------------------+------+-----------------------------------------------------------------+------------------------------------------+
| ID  | USER | HOST                | COMMAND          | TIME | STATE                                                           | info                                     |
+-----+------+---------------------+------------------+------+-----------------------------------------------------------------+------------------------------------------+
|   9 | repl | 192.168.164.4:39346 | Binlog Dump GTID |  132 | Source has sent all binlog to replica; waiting for more updates | NULL                                     |
| 159 | root | localhost           | Query            |    0 | executing                                                       | SELECT ID, USER, HOST, COMMAND, TIME, ST |
+-----+------+---------------------+------------------+------+-----------------------------------------------------------------+------------------------------------------+
```

A processlist is a snapshot. Statements that finish in milliseconds are
almost never caught in one, even when they make up most of the load — run
the exercise workload and look: the application's sessions are rarely
visible. Use the processlist for things that *last*: a long-running
statement, a session idle inside an open transaction (`Command: Sleep`
with a large `TIME`), a pile-up in one `STATE`. For the rest, use digests.
[`sys.session`](https://dev.mysql.com/doc/refman/8.4/en/sys-session.html)
is the processlist joined with the current statement's latency, rows
examined and last wait.

## Wait analysis, briefly

When a statement is slow, its time went somewhere: CPU, I/O, or waiting
for a lock or a mutex. The Performance Schema's wait instruments sum that
time per event name
([manual: wait summaries](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-wait-summary-tables.html)):

```sql test
SELECT * FROM sys.waits_global_by_latency LIMIT 5;
```

```text
+--------------------------------------+----------+---------------+-------------+-------------+
| events                               | total    | total_latency | avg_latency | max_latency |
+--------------------------------------+----------+---------------+-------------+-------------+
| wait/io/table/sql/handler            | 11008336 | 7.20 s        | 627.21 ns   | 495.53 ms   |
| wait/io/file/innodb/innodb_log_file  |    56183 | 6.14 s        | 109.22 us   | 36.29 ms    |
| wait/io/file/innodb/innodb_data_file |    20121 | 2.05 s        | 101.90 us   | 18.43 ms    |
| wait/io/file/innodb/innodb_temp_file |     1359 | 213.52 ms     | 157.10 us   | 8.64 ms     |
| wait/io/file/sql/binlog              |    15972 | 94.70 ms      | 5.90 us     | 10.37 ms    |
+--------------------------------------+----------+---------------+-------------+-------------+
```

On a fresh lab this is mostly the dataset load:

- `wait/io/file/innodb/innodb_log_file` is redo log I/O — the cost of
  commits with `innodb_flush_log_at_trx_commit = 1`.
- `wait/io/table/sql/handler` is row access through the storage engine.
  It also absorbs time spent waiting for InnoDB row locks: after module
  8's lock pile-up scenario, its `max_latency` reads about 20 s — one
  statement that waited out `innodb_lock_wait_timeout`.
- `innodb_data_file` is page reads and writes against the tablespaces.

These are server-wide totals since start-up, so compare two snapshots
rather than reading absolute numbers. Many wait instruments (mutexes,
rwlocks) are disabled by default because timing them has a cost; enable
them deliberately, on one server, for a bounded time. For lock waits
specifically, `sys.innodb_lock_waits` (module 3) shows who blocks whom.

## Non-sargable predicates

A predicate is **sargable** (*Search ARGument ABLE*) when the optimizer can
turn it into an index range: `column <op> constant`. Three common patterns
break that, and they look harmless in code review.

### 1. A function wrapped around the column

The index on `email` stores email values, not the result of a function of
them; the optimizer cannot search it for `SUBSTRING_INDEX(email, '@', 1)`:

```sql test
EXPLAIN SELECT id, full_name FROM shop.customers
WHERE SUBSTRING_INDEX(email, '@', 1) = 'customer4242';
EXPLAIN SELECT id, full_name FROM shop.customers
WHERE email = 'customer4242@example.test';
```

```text
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
| id | select_type | table     | partitions | type | possible_keys | key  | key_len | ref  | rows  | filtered | Extra       |
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
|  1 | SIMPLE      | customers | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 20092 |   100.00 | Using where |
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
+----+-------------+-----------+------------+-------+--------------------+--------------------+---------+-------+------+----------+-------+
| id | select_type | table     | partitions | type  | possible_keys      | key                | key_len | ref   | rows | filtered | Extra |
+----+-------------+-----------+------------+-------+--------------------+--------------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | customers | NULL       | const | uk_customers_email | uk_customers_email | 1022    | const |    1 |   100.00 | NULL  |
+----+-------------+-----------+------------+-------+--------------------+--------------------+---------+-------+------+----------+-------+
```

The same applies to `DATE(created_at) = ...`, `YEAR(...)`, `LOWER(...)`,
arithmetic such as `price_cents / 100 > 50`, and `COALESCE(col, ...)`.

**Application-side fix:** rewrite the predicate so the column stands alone
— `email = ?`, or `created_at >= '2025-03-14' AND created_at < '2025-03-15'`
instead of `DATE(created_at) = '2025-03-14'`. Best when you own the code.

**Database-side fix:** index the expression itself. A **functional key
part** (MySQL 8.0.13 and later) indexes the value of an expression
([manual: CREATE INDEX](https://dev.mysql.com/doc/refman/8.4/en/create-index.html));
note the double parentheses:

```sql test
CREATE INDEX idx_customers_local_part
  ON shop.customers ((SUBSTRING_INDEX(email, '@', 1)));
EXPLAIN SELECT id, full_name FROM shop.customers
WHERE SUBSTRING_INDEX(email, '@', 1) = 'customer4242';
EXPLAIN SELECT id, full_name FROM shop.customers
WHERE SUBSTRING_INDEX(email, '@', 1) LIKE 'customer42%';
DROP INDEX idx_customers_local_part ON shop.customers;
```

```text
+----+-------------+-----------+------------+------+--------------------------+--------------------------+---------+-------+------+----------+-------+
| id | select_type | table     | partitions | type | possible_keys            | key                      | key_len | ref   | rows | filtered | Extra |
+----+-------------+-----------+------------+------+--------------------------+--------------------------+---------+-------+------+----------+-------+
|  1 | SIMPLE      | customers | NULL       | ref  | idx_customers_local_part | idx_customers_local_part | 1023    | const |    1 |   100.00 | NULL  |
+----+-------------+-----------+------------+------+--------------------------+--------------------------+---------+-------+------+----------+-------+
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
| id | select_type | table     | partitions | type | possible_keys | key  | key_len | ref  | rows  | filtered | Extra       |
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
|  1 | SIMPLE      | customers | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 20120 |   100.00 | Using where |
+----+-------------+-----------+------------+------+---------------+------+---------+------+-------+----------+-------------+
```

The second plan is the catch. A functional index is implemented as a
hidden virtual generated column, and the optimizer matches a query
expression against it only with `=`, `<`, `<=`, `>`, `>=`, `BETWEEN` and
`IN()`, and only when the expression matches the definition
([manual: optimizer use of generated column indexes](https://dev.mysql.com/doc/refman/8.4/en/generated-column-index-optimizations.html)).
`LIKE` does not qualify. An explicit generated column with an ordinary
index (`ADD COLUMN ... AS (expr) VIRTUAL, ADD INDEX (...)`) works the same
way and is easier to see in `SHOW CREATE TABLE`.

Either way, a database-side fix is a contract with the application's exact
SQL: if a developer later writes `DATE(o.created_at)` through an ORM that
casts differently, the index silently stops matching. Write it down.

### 2. Implicit type conversion

Comparing a string column with a number makes MySQL compare *as numbers*
([manual: type conversion](https://dev.mysql.com/doc/refman/8.4/en/type-conversion.html)),
converting every row's value — so no index range is possible. A
`lab` schema keeps the demo away from the shop data:

```sql test
CREATE SCHEMA lab;
CREATE TABLE lab.parcels (
  id INT PRIMARY KEY,
  tracking_code VARCHAR(20) NOT NULL,
  KEY idx_tracking (tracking_code)
);
INSERT INTO lab.parcels
  SELECT id, LPAD(id * 7, 10, '0') FROM shop.orders WHERE id <= 50000;
ANALYZE TABLE lab.parcels;
EXPLAIN SELECT id FROM lab.parcels WHERE tracking_code = 0000002401;
SHOW WARNINGS;
EXPLAIN SELECT id FROM lab.parcels WHERE tracking_code = '0000002401';
```

```text
+-------------+---------+----------+----------+
| Table       | Op      | Msg_type | Msg_text |
+-------------+---------+----------+----------+
| lab.parcels | analyze | status   | OK       |
+-------------+---------+----------+----------+
+----+-------------+---------+------------+-------+---------------+--------------+---------+------+-------+----------+--------------------------+
| id | select_type | table   | partitions | type  | possible_keys | key          | key_len | ref  | rows  | filtered | Extra                    |
+----+-------------+---------+------------+-------+---------------+--------------+---------+------+-------+----------+--------------------------+
|  1 | SIMPLE      | parcels | NULL       | index | idx_tracking  | idx_tracking | 82      | NULL | 50283 |    10.00 | Using where; Using index |
+----+-------------+---------+------------+-------+---------------+--------------+---------+------+-------+----------+--------------------------+
+---------+------+------------------------------------------------------------------------------------------------------------------------+
| Level   | Code | Message                                                                                                                |
+---------+------+------------------------------------------------------------------------------------------------------------------------+
| Warning | 1739 | Cannot use ref access on index 'idx_tracking' due to type or collation conversion on field 'tracking_code'             |
| Warning | 1739 | Cannot use range access on index 'idx_tracking' due to type or collation conversion on field 'tracking_code'           |
| Note    | 1003 | /* select#1 */ select `lab`.`parcels`.`id` AS `id` from `lab`.`parcels` where (`lab`.`parcels`.`tracking_code` = 2401) |
+---------+------+------------------------------------------------------------------------------------------------------------------------+
+----+-------------+---------+------------+------+---------------+--------------+---------+-------+------+----------+-------------+
| id | select_type | table   | partitions | type | possible_keys | key          | key_len | ref   | rows | filtered | Extra       |
+----+-------------+---------+------------+------+---------------+--------------+---------+-------+------+----------+-------------+
|  1 | SIMPLE      | parcels | NULL       | ref  | idx_tracking  | idx_tracking | 82      | const |    1 |   100.00 | Using index |
+----+-------------+---------+------------+------+---------------+--------------+---------+-------+------+----------+-------------+
```

`possible_keys` names the index and `key` even uses it — but as type
`index`, a scan of all ~50 000 entries, not a lookup. Warning 1739 says why.
The `Note` shows the literal arrived as the number `2401`: the leading
zeros were gone before MySQL saw them.

It changes results, too, not only speed:

```sql test
SELECT
  (SELECT COUNT(*) FROM lab.parcels WHERE tracking_code = 2401)   AS as_number,
  (SELECT COUNT(*) FROM lab.parcels WHERE tracking_code = '2401') AS as_string;
DROP SCHEMA lab;
```

```text
+-----------+-----------+
| as_number | as_string |
+-----------+-----------+
|         1 |         0 |
+-----------+-----------+
```

The fix belongs in the application: bind the parameter as a string. (Typed
drivers usually do; hand-built SQL and some ORMs with loosely typed
languages do not.) There is no clean database-side fix — a generated
column does not help, because the query compares the original column.
Changing the column to a numeric type would make the index usable but
destroy the leading zeros, which are data. The database-side job is to
*find* it: the warning above, `SUM_NO_INDEX_USED` in the digest table, and
`Rows_examined` in the slow log.

### 3. Leading wildcard

```sql test
EXPLAIN SELECT id, name FROM shop.products WHERE name LIKE '%pump%';
EXPLAIN SELECT id, sku  FROM shop.products WHERE sku  LIKE 'SKU-0004%';
```

```text
+----+-------------+----------+------------+------+---------------+------+---------+------+------+----------+-------------+
| id | select_type | table    | partitions | type | possible_keys | key  | key_len | ref  | rows | filtered | Extra       |
+----+-------------+----------+------------+------+---------------+------+---------+------+------+----------+-------------+
|  1 | SIMPLE      | products | NULL       | ALL  | NULL          | NULL | NULL    | NULL | 1000 |    11.11 | Using where |
+----+-------------+----------+------------+------+---------------+------+---------+------+------+----------+-------------+
+----+-------------+----------+------------+-------+-----------------+-----------------+---------+------+------+----------+--------------------------+
| id | select_type | table    | partitions | type  | possible_keys   | key             | key_len | ref  | rows | filtered | Extra                    |
+----+-------------+----------+------------+-------+-----------------+-----------------+---------+------+------+----------+--------------------------+
|  1 | SIMPLE      | products | NULL       | range | uk_products_sku | uk_products_sku | 130     | NULL |  100 |   100.00 | Using where; Using index |
+----+-------------+----------+------------+-------+-----------------+-----------------+---------+------+------+----------+--------------------------+
```

A B-tree is sorted by the leading characters; `'SKU-0004%'` is a range,
`'%pump%'` is not. On 1 000 products that does not matter. On 10 million
it does, and the fix is a different access path: a `FULLTEXT` index with
`MATCH ... AGAINST` (word search, different semantics —
[manual](https://dev.mysql.com/doc/refman/8.4/en/fulltext-search.html)) or
a search engine outside MySQL. Both need the application to change.

### Choosing where to fix

| Prefer the database side when | Prefer the application side when |
|---|---|
| The SQL is generated or shipped by a vendor and cannot change soon. | You own the code and can deploy today. |
| An exact-expression match is stable (one code path). | The same predicate appears in many shapes. |
| You need relief now, and the rewrite follows. | The fix also corrects results (type conversion). |

Every index also costs on writes and in the buffer pool. Before adding
one, check `sys.schema_unused_indexes` and
`sys.schema_redundant_indexes` for ones you can drop.

## Common mistakes and troubleshooting

- **Sorting by average latency.** The slowest statement on average is
  often a nightly report. Sort by total time to find what the server spends
  its day on; then look at averages and p95 to see who suffers.
- **`SET GLOBAL long_query_time` "did nothing".** Existing connections keep
  their session value. Connection pools may hold sessions for hours.
- **Leaving `long_query_time = 0` on globally.** Every statement is written
  to disk. Use it per session, or globally for minutes, with an eye on the
  disk.
- **Truncating Performance Schema tables on a shared server.** Others'
  investigations and the exporter's counters depend on them. Snapshot and
  diff.
- **Trusting `possible_keys`.** It lists candidates. The `key` and `type`
  columns, and warnings, say what happens.
- **Adding an index on `created_at` for `DATE(created_at) = ?`.** It will
  not be used. Index the expression, or rewrite the predicate.

## Further reading

- MySQL 8.4 Reference Manual:
  [The Slow Query Log](https://dev.mysql.com/doc/refman/8.4/en/slow-query-log.html),
  [Statement Digests and Sampling](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-digests.html),
  [Statement Summary Tables](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-statement-summary-tables.html),
  [sys Schema](https://dev.mysql.com/doc/refman/8.4/en/sys-schema.html),
  [Optimizer Use of Generated Column Indexes](https://dev.mysql.com/doc/refman/8.4/en/generated-column-index-optimizations.html),
  [Type Conversion in Expression Evaluation](https://dev.mysql.com/doc/refman/8.4/en/type-conversion.html).
- Brendan Gregg, [The USE Method](https://www.brendangregg.com/usemethod.html).
- Percona Toolkit,
  [pt-query-digest](https://docs.percona.com/percona-toolkit/pt-query-digest.html)
  (optional).

## Next

Do the [exercise](exercise.md): an application is running, one statement
is eating the server, and you may not change its SQL. Then check yourself
with the [quiz](quiz.md). Module 6 covers backup and restore.
