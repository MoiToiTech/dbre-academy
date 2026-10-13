# Exercise 5 — One statement is eating the server

`time: ~40 min` · `scenario: 05-slow-query`

An application is running against the primary as the `app` account: order
pages, a customer's recent orders, stock lookups by SKU and a back-office
dashboard. Users say the dashboard is slow and the database "feels busy".
Nothing is in the slow query log.

Your job:

1. Find the statement that costs the server the most time.
2. Explain why it is expensive.
3. Fix it **in the database**. The application's SQL belongs to another
   team and cannot change this week.
4. Prove the fix with numbers, not with "it feels faster".

## Start the scenario

```bash test
./lab scenario setup 05-slow-query
```

```text
==> Clearing statement digest statistics so the workload starts from zero
==> Application workload running in container dbre-05-workload (user 'app').
Users report that the back-office dashboard is slow and the database is busy.
Find the statement that costs the server the most time and fix it in the
database — the application's SQL cannot be changed. Then: ./lab check 05-slow-query
```

The workload runs in its own container (`dbre-05-workload`) and keeps going
until you reset the scenario. It reconnects for every batch of requests,
like many web applications, so global variable changes reach it within a
second. Give it 20 seconds to build up statistics:

```bash test
sleep 20
```

## Part 1 — Why the slow log is empty

```sql test
SELECT @@long_query_time,
       (SELECT VARIABLE_VALUE FROM performance_schema.global_status
        WHERE VARIABLE_NAME = 'Slow_queries') AS slow_queries;
```

`long_query_time` is 1 second. Keep that in mind when you find the
offender's average latency.

Lower the threshold for a few seconds — globally, because the application's
sessions are not yours — and summarise what was captured:

```bash test
./lab sql -e "SET GLOBAL long_query_time = 0.005"
sleep 10
./lab sql -e "SET GLOBAL long_query_time = 1"
./lab exec primary mysqldumpslow -s t /var/lib/mysql/slow.log
```

Questions to answer for yourself:

- Which statements appear at 5 ms that did not at 1 s?
- How much of the server's time do they account for per second?
- What would happen to the disk if you left the threshold at 5 ms on a
  server doing 10 000 statements a second?

## Part 2 — Rank by total time

Use the Performance Schema, which saw every execution. The application
connects with `shop` as its default database, so its digests carry
`SCHEMA_NAME = 'shop'`:

```sql test
SELECT LEFT(DIGEST_TEXT, 60) AS digest_text, COUNT_STAR AS calls,
       format_pico_time(SUM_TIMER_WAIT) AS total,
       format_pico_time(AVG_TIMER_WAIT) AS avg,
       ROUND(SUM_ROWS_EXAMINED / COUNT_STAR) AS exam_per_call
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'shop'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 5;
```

Then confirm from a second angle — who is generating the load, and which
statements scan whole tables:

```sql test
SELECT user, statements, statement_latency, table_scans
FROM sys.user_summary WHERE user = 'app';

SELECT sys.format_statement(query) AS query, exec_count, rows_examined_avg
FROM sys.`x$statements_with_full_table_scans`
WHERE db = 'shop';
```

Write down, before you change anything:

- the offender's digest text and one real sample (`QUERY_SAMPLE_TEXT`);
- calls, total time, average time and rows examined per call;
- its share of the application's total statement latency.

<details>
<summary>Hint 1 — what to look for</summary>

The top statement by total time examines about 200 000 rows per call to
return one row. `shop.orders` has 200 000 rows. Run `EXPLAIN` on the sample
text (prefix the table with `shop.` or run `USE shop` first).

</details>

<details>
<summary>Hint 2 — why no index helps yet</summary>

Look at the `WHERE` clause. Which column does it filter on, and what is
wrapped around that column? Would an ordinary index on that column be used?
Try it with `EXPLAIN` — and then drop the index again if it is not used:
an unused index still costs on every write.

</details>

## Part 3 — Fix it in the database

Make the statement able to use an index **without changing its text**.
The lesson covers two ways; either passes the check. Verify with `EXPLAIN`
before you run the check: you want `type: ref` or `range`, a `key`, and
`rows` in the hundreds, not 200 000.

When you are done:

```bash
./lab check 05-slow-query
```

The check runs `EXPLAIN` on the application's statement, then watches the
next executions of the live workload in the Performance Schema and
requires rows examined per call to drop from ~200 000 to a few hundred,
with no errors. Until you have fixed it, it fails:

```bash test expect-error
./lab check 05-slow-query
```

```text
Checking 05-slow-query
  FAIL EXPLAIN of the daily-sales query: type=ALL, key=NULL, rows≈199800
       hint: find the statement with the highest SUM_TIMER_WAIT in sys.statement_analysis,
       hint: then ask why its WHERE clause cannot use an index (module 4, and this lesson's
       hint: section on non-sargable predicates). The application's SQL cannot be changed.
  FAIL last 9 executions examined 200000 rows each on average
       hint: rows_examined per call should drop from ~200 000 to a few hundred
  PASS the application's query still succeeds (errors in the last 9 calls)
2 check(s) failed.
```

A reference fix is in `labs/scenarios/05-slow-query/solve.sh`. Try first;
it is two lines and the reasoning is the point.

<details>
<summary>Solution and discussion</summary>

The dashboard query is

```sql
SELECT COUNT(*), SUM(total_cents) FROM orders WHERE DATE(created_at) = '2025-03-14'
```

`DATE(created_at)` is a function of the column, so an index on
`created_at` cannot be searched for it: every execution reads all 200 000
rows. At about 13 ms per call it never reaches a 1-second slow log, yet it
is over 90% of the application's statement time.

Database-side fix — a functional index on exactly that expression:

```sql
CREATE INDEX idx_orders_created_date ON shop.orders ((DATE(created_at)));
```

or, equivalently, a generated column with an ordinary index:

```sql
ALTER TABLE shop.orders
  ADD COLUMN created_date DATE AS (DATE(created_at)) VIRTUAL,
  ADD INDEX idx_orders_created_date (created_date);
```

Either way `EXPLAIN` shows `type: ref`, `rows: 275`, and the check's
measurement drops to about 274 rows examined per call.

The application-side fix, for when the other team can deploy, is a range
on the bare column plus an ordinary index on `created_at`:

```sql
WHERE created_at >= '2025-03-14' AND created_at < '2025-03-15'
```

That version also serves "last 7 days" and "this month" from the same
index; the functional index serves only whole-day equality.

</details>

## Part 4 — Measure the improvement

After the fix, take before/after numbers from the same place you found the
problem. Statistics since setup mix both periods, so either clear them
(fine in the lab) or compare two snapshots a minute apart:

```sql
TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;
-- wait 20 seconds, then re-run the Part 2 query
```

What we measured in the lab, 20 seconds each side (your timings differ):

| | total | avg | rows examined per call |
|---|---|---|---|
| Before (88 calls) | 1.17 s | 13.35 ms | 200 000 |
| After (94 calls) | 57.85 ms | 615.41 µs | 274 |

The dashboard statement may well stay at the top of the list — it still
does the most work per call — but the server spends about twenty times
less time on it. "Top of the list" is relative; the absolute numbers are
the result.

## Stretch

- Turn on `log_queries_not_using_indexes` for 10 seconds (and set
  `long_query_time` back to 1). Which statements does it log, and why is it
  so noisy on a server with small lookup tables? What does
  `log_throttle_queries_not_using_indexes` do about it?
- The digest table also has `QUANTILE_95` and `QUANTILE_99`. Compare them
  for the offender before and after the fix.

## Clean up

```bash test
./lab scenario reset 05-slow-query
```

Reset stops the workload, drops any index or column you added to
`shop.orders`, and restores `long_query_time`, `log_slow_extra`,
`log_queries_not_using_indexes` and `min_examined_row_limit`.
