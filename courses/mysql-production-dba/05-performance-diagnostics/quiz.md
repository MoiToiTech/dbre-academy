# Quiz 5 — Performance diagnostics and slow queries

Answer from memory first, then open the answer.

**1.** A colleague's first move on "the database is slow" is to raise
`innodb_buffer_pool_size`. What would you do first, and why?

<details>
<summary>Answer</summary>

Find out where the server's time goes: rank statement digests by total
latency (`sys.statement_analysis`) and check what changed. Configuration
changes fix measured resource problems; without knowing which statements
consume the time — and whether they are short of memory at all — a bigger
buffer pool is a guess. One full-scanning statement is fixed by an index,
not by memory.

</details>

**2.** `long_query_time` is 1. A statement takes 15 ms and runs 100 times
a second. Is it in the slow log? How much server time does it cost?

<details>
<summary>Answer</summary>

No — it never exceeds 1 second. It costs 1.5 seconds of statement time
every second: possibly more than everything that *is* in the slow log. This
is why you rank by total time in the Performance Schema rather than relying
on a threshold.

</details>

**3.** You run `SET GLOBAL long_query_time = 0.1`, but the application's
slow queries still do not appear. Why might that be?

<details>
<summary>Answer</summary>

`long_query_time` is copied into each session when it connects; `SET
GLOBAL` affects only new connections. A connection pool that keeps sessions
open for hours keeps the old value until it reconnects.

</details>

**4.** `SUM_TIMER_WAIT` for a digest is `753160000000`. How long is that?

<details>
<summary>Answer</summary>

Performance Schema timers are in picoseconds: 753 160 000 000 ps =
0.753 s. `format_pico_time()` does the conversion.

</details>

**5.** A statement's digest row shows `SUM_NO_INDEX_USED = 0`, yet it
examines 200 000 rows per call to return 5. How?

<details>
<summary>Answer</summary>

It uses an index — but reads all of it: a full *index* scan (`type:
index` in `EXPLAIN`), for example a `GROUP BY` walked in index order. The
"no index used" counter only flags statements that used no index at all.
Rows examined per call is the better efficiency signal.

</details>

**6.** Why is `log_queries_not_using_indexes` rarely left on in production?

<details>
<summary>Answer</summary>

It logs every statement that uses no index for row lookups, however fast:
scans of small lookup tables, `SELECT COUNT(*)` on tiny tables, and so on.
The log fills with harmless entries and the real problems drown. If you use
it, use it briefly and with `log_throttle_queries_not_using_indexes`.

</details>

**7.** You look at `SHOW PROCESSLIST` during a load spike and see nothing
but idle connections. Does that mean the database is not the problem?

<details>
<summary>Answer</summary>

No. The processlist is a snapshot; statements that complete in
milliseconds are rarely caught in one, even when they are most of the
load. Statement digests and the `Questions` / `Threads_running` counters
show the work that a snapshot misses.

</details>

**8.** Why does `WHERE DATE(created_at) = '2025-03-14'` not use an index on
`created_at`? Give one database-side and one application-side fix.

<details>
<summary>Answer</summary>

The index stores `created_at` values in order; the predicate is on a
function of the column, which the optimizer cannot map to a range of the
index. Database side: a functional index `((DATE(created_at)))` or a
generated column with an index. Application side: rewrite as
`created_at >= '2025-03-14' AND created_at < '2025-03-15'`, which an
ordinary index on `created_at` serves.

</details>

**9.** After adding a functional index on `(SUBSTRING_INDEX(email, '@', 1))`,
`WHERE SUBSTRING_INDEX(email, '@', 1) = 'x'` uses it but
`WHERE SUBSTRING_INDEX(email, '@', 1) LIKE 'x%'` does not. Why?

<details>
<summary>Answer</summary>

The optimizer matches an expression against a generated-column index (a
functional index is one) only for `=`, `<`, `<=`, `>`, `>=`, `BETWEEN` and
`IN()`. `LIKE` is not on the list.

</details>

**10.** `tracking_code` is `VARCHAR(20)` with an index. The application
runs `WHERE tracking_code = 2401`. What happens, and what is the right fix?

<details>
<summary>Answer</summary>

MySQL compares as numbers, converting every row's value, so the index
cannot be used for a lookup (`EXPLAIN` shows a scan and warning 1739). It
can also return different rows: `'0000002401'` equals the number 2401 but
not the string `'2401'`. The fix is in the application — pass the value as
a string. Changing the column to a number would lose leading zeros.

</details>

**11.** A slow log entry shows `Query_time: 20.4`, `Lock_time: 20.4`,
`Rows_examined: 0`. Is this statement expensive?

<details>
<summary>Answer</summary>

No — it was blocked. It spent its time waiting for a lock held by another
transaction and did almost no work. Look for the blocker
(`sys.innodb_lock_waits`), not for an index.

</details>
