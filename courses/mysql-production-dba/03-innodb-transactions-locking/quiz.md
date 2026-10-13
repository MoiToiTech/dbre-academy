# Module 3 — Quiz

Answer from memory first, then open the answer.

**1. A server has `innodb_flush_log_at_trx_commit = 2`. The operating system
crashes. What can be lost, and which log is responsible?**

<details><summary>Answer</summary>

Roughly the last second of committed transactions (the manual notes that
once-per-second flushing is not guaranteed). With `2`, InnoDB writes the redo
log to the operating system at each commit but flushes it to disk only about
once per second. Redo that was written but not yet flushed sits in the OS
page cache, which an OS crash or power failure discards. The redo log is
the log responsible; with `1` it is flushed at every commit.

</details>

**2. A developer runs `START TRANSACTION; DELETE FROM lab.t; TRUNCATE
lab.audit; ROLLBACK;` and is surprised the rows in `lab.t` are gone. Why?**

<details><summary>Answer</summary>

`TRUNCATE` is DDL and causes an implicit commit before it runs, so the
`DELETE` was committed. The `ROLLBACK` had nothing to undo.

</details>

**3. Under REPEATABLE READ, transaction A runs `SELECT on_hand ...` (443).
Transaction B updates the row to 433 and commits. A runs the same plain
`SELECT` again, then `SELECT ... FOR UPDATE`. What does each return?**

<details><summary>Answer</summary>

The plain `SELECT` returns 443: a consistent read reuses the snapshot taken
at A's first read. `FOR UPDATE` is a locking read; it reads the latest
committed version, 433, and locks it.

</details>

**4. Why can an idle transaction that has only run one `SELECT` make every
other query on the server slower over time?**

<details><summary>Answer</summary>

Its read view stops purge from removing undo records newer than it, on all
tables. The history list length grows, undo tablespaces grow, and consistent
reads have to walk longer version chains to rebuild old row versions.

</details>

**5. `performance_schema.data_locks` shows `X,GAP` on index record
`15003, 2672` of `idx_orders_customer`. What does that lock prevent, and what
does it not prevent?**

<details><summary>Answer</summary>

It prevents inserts into the gap immediately before that index entry, for
example a new order for customer 15002. It does not lock the entry
`15003, 2672` itself: another transaction can still update or lock that
order.

</details>

**6. A session's `UPDATE` fails with error 1205. The application logs the
error and then commits. What ends up in the database?**

<details><summary>Answer</summary>

Every change the transaction made before the failed statement. By default
(`innodb_rollback_on_timeout = OFF`) InnoDB rolls back only the statement that
timed out, so the commit makes the rest of the transaction durable. On error
1205 the application should roll back and retry the whole transaction.

</details>

**7. `sys.innodb_lock_waits` shows `blocking_query: NULL` and the blocking
session's command is `Sleep`. You run the suggested `KILL QUERY`. What
happens?**

<details><summary>Answer</summary>

Nothing useful. The session is idle in a transaction; there is no statement
to stop, and its transaction and locks remain. `KILL <id>` ends the
connection, which rolls the transaction back and releases the locks.

</details>

**8. Two transactions deadlock. One has updated 3 rows, the other 1. Which
one does InnoDB roll back, and what should the application do?**

<details><summary>Answer</summary>

InnoDB prefers to roll back the smaller transaction, measured by rows
inserted, updated or deleted, so usually the one with 1 row. The victim gets
error 1213 and its whole transaction is rolled back; the application should
retry it. Locking rows in a consistent order avoids that particular deadlock.

</details>

**9. `ALTER TABLE shop.customers ...` has been "Waiting for table metadata
lock" for ten minutes, and now simple `SELECT`s on the table hang too. Why do
the `SELECT`s wait, and why has nothing timed out?**

<details><summary>Answer</summary>

The `ALTER` waits for an exclusive metadata lock because an open transaction
holds a shared one. Pending exclusive requests have priority over new shared
ones, so new `SELECT`s queue behind the `ALTER`. The metadata lock timeout,
`lock_wait_timeout`, defaults to one year, so none of them gives up.

</details>

**10. In `sys.schema_table_lock_waits`, both the idle session and the
`ALTER` appear as `blocking_pid`. How do you tell which one to end?**

<details><summary>Answer</summary>

The root blocker is the `blocking_pid` that is not itself waiting: it never
appears as a `waiting_pid`. The `ALTER` holds `SHARED_UPGRADABLE` and is
listed as blocking because the view pairs every waiter with every lock
holder on the table.

</details>

**11. What should every migration session set before running DDL on a busy
table, and why?**

<details><summary>Answer</summary>

A short `lock_wait_timeout` (a few seconds). If an open transaction blocks the
DDL, it fails quickly with error 1205 instead of queueing every new query on
the table behind it; the migration can then be retried.

</details>
