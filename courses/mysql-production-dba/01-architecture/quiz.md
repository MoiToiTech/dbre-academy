# Quiz — Database architecture and MySQL internals

Answer each question before opening the answer. If you get one wrong,
re-read the section named in the answer.

**1.** `Connections` rose by 5 000 in the last hour and `Threads_created`
rose by 4 800. What does that tell you, and which variable is involved?

<details>
<summary>Answer</summary>

Almost every new connection needed a new OS thread: the thread cache is not
absorbing the connection churn. Look at `thread_cache_size` (and at why the
application opens so many short connections — a connection pool usually
fixes the cause). See "One process, many threads".

</details>

**2.** `top -H` on a database host shows one `mysqld` thread at 100% CPU with
thread id 48211. How do you find the query it is running?

<details>
<summary>Answer</summary>

```sql
SELECT PROCESSLIST_ID, PROCESSLIST_USER, PROCESSLIST_INFO
FROM performance_schema.threads
WHERE THREAD_OS_ID = 48211;
```

`THREAD_OS_ID` is the Linux thread id that `top -H` and `ps -L` show.

</details>

**3.** Which layer chooses whether a query uses an index — the SQL layer or
InnoDB? Which counters show how many rows InnoDB was then asked for?

<details>
<summary>Answer</summary>

The optimizer, in the SQL layer, chooses the plan. The executor then calls
the engine through the handler API; the `Handler_read_*` status counters
count those calls (`Handler_read_key` for index lookups, `Handler_read_next`
for index range steps, `Handler_read_rnd_next` for full-scan steps).

</details>

**4.** A colleague's tuning checklist says to "check change buffer merges
and adaptive hash index contention first". On a default MySQL 8.4 server,
how useful is that advice?

<details>
<summary>Answer</summary>

Not very: both are off by default in 8.4 (`innodb_change_buffering = none`,
`innodb_adaptive_hash_index = OFF`). The checklist was written for an older
version. Check what the server actually runs with before following it.

</details>

**5.** A 40 GiB table was dropped, yet the disk has the same free space.
`ibdata1` is 60 GiB. What happened, and what are your options?

<details>
<summary>Answer</summary>

The table lived in the system tablespace (created with `innodb_file_per_table
= OFF` at the time, or with `TABLESPACE innodb_system`). Dropping it freed
space inside `ibdata1` that InnoDB can reuse, but the file never shrinks.
The only way to make `ibdata1` smaller is to restore the data into a new
instance (logical dump and reload, or a replica built that way). Make sure
`innodb_file_per_table = ON` so it does not happen again.

</details>

**6.** Why can't MySQL replicate using the redo log, and why can't it do
crash recovery from the binary log alone?

<details>
<summary>Answer</summary>

The redo log is physical (page changes), InnoDB-specific, contains
uncommitted and rolled-back work, and is overwritten in a circle. The binary
log is logical and holds committed transactions in commit order, which is
what a replica needs — but it says nothing about which pages reached disk,
which crash recovery needs.

</details>

**7.** The server is killed between InnoDB preparing a transaction and the
transaction being written to the binary log. What happens to it at restart,
and why is that the right outcome?

<details>
<summary>Answer</summary>

It is rolled back. It is not in the binary log, so no replica has it and
point-in-time recovery would not replay it. Committing it would make the
primary diverge from its replicas. Prepared transactions that *did* reach
the binary log are committed, for the same reason. This only holds with
`sync_binlog = 1` and `innodb_flush_log_at_trx_commit = 1`.

</details>

**8.** What does the doublewrite buffer protect against that the redo log
cannot?

<details>
<summary>Answer</summary>

Torn (partially written) pages. Redo records describe changes to a page and
need an intact page to apply them to. If a crash leaves a 16 KiB page half
old and half new, recovery restores it from its doublewrite copy first, then
applies redo.

</details>

**9.** A batch job had a transaction open for 40 minutes when the server
crashed. The server is back up and accepting connections. Is the incident
over?

<details>
<summary>Answer</summary>

Not yet. Rollback of incomplete transactions runs in the background after
startup and can take several times as long as the transaction ran. Until it
finishes, new connections may hit lock conflicts with the recovered
transaction, and the undo work competes for I/O
([InnoDB Recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)).
Watch the error log for `Rollback of trx with id ... completed`.

</details>

**10.** For each question, which schema would you query first:
`information_schema`, `performance_schema` or `sys`?
(a) Which tables have no primary key? (b) Which statements used the most
total time since startup? (c) Where did the value of `max_connections` come
from?

<details>
<summary>Answer</summary>

(a) `information_schema` (`TABLES`, `STATISTICS`) — metadata.
(b) `performance_schema.events_statements_summary_by_digest`, or its readable
`sys.statement_analysis` view.
(c) `performance_schema.variables_info` — covered in Module 2.

</details>
