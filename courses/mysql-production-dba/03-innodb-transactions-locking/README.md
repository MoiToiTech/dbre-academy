# Module 3 — InnoDB transactions, MVCC and locking

`time: ~75 min` · `lab: ./lab scenario setup 03-lock-contention` · `level: fundamentals`

When a healthy MySQL server with idle CPUs and quiet disks stops answering,
the cause is usually not the hardware. It is a transaction that nobody
committed: it holds row locks that make application requests time out, a
metadata lock that queues every query on a table behind a schema change, or a
read view that stops InnoDB from purging old row versions. This module shows
how InnoDB implements transactions, which locks it takes and why, and how to
find the one session that is holding everyone else up.

## Learning objectives

By the end of this module you can:

- map each ACID property to the InnoDB mechanism behind it: redo log, undo
  log, doublewrite buffer, binary log;
- explain autocommit, implicit commits and why `autocommit=0` leaks
  transactions;
- predict what a consistent read and a locking read return under
  REPEATABLE READ and READ COMMITTED;
- explain how a long-running transaction blocks purge, and read the history
  list length;
- read `performance_schema.data_locks` and name record, gap, next-key and
  insert intention locks;
- diagnose a lock wait with `sys.innodb_lock_waits` and a metadata lock queue
  with `sys.schema_table_lock_waits`, find the root blocker and end it;
- read the `LATEST DETECTED DEADLOCK` section and decide what to change.

## Prerequisites

- Modules 1 and 2. The lab is running (`./lab up`) on the baseline dataset.
- Run commands from the `labs/` directory. SQL blocks go into `./lab sql`;
  bash blocks run as they are.
- Several examples need two or three sessions at once. They start the extra
  sessions in the background with `&` and wait for them at the end, so each
  block runs in one go. You can also open two terminals with `./lab sql` and
  type the statements by hand; the result is the same.

## 1. What a commit costs

ACID is a promise; InnoDB keeps it with four structures
([manual: InnoDB and the ACID model](https://dev.mysql.com/doc/refman/8.4/en/mysql-acid.html)):

| Property | Mechanism |
|---|---|
| Atomicity | Undo log: every change records how to reverse it |
| Consistency | Doublewrite buffer and crash recovery: no torn pages |
| Isolation | Locks plus MVCC read views built from the undo log |
| Durability | Redo log flushed at commit; binary log synced with it |

- The **redo log** is a write-ahead log of page changes. A commit is durable
  once its redo records are on disk; the data pages themselves are written
  later by background flushing. Crash recovery replays the redo log
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html)).
- The **undo log** holds the previous version of every changed row. Rollback
  uses it, and so do other transactions that need to see the row as it was
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-logs.html)).
- The **doublewrite buffer** receives each page before it is written to its
  place in the data file, so a page half-written during a crash can be
  restored from the intact copy
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-doublewrite-buffer.html)).
- The **binary log** is the server's log of committed changes, used by
  replication and point-in-time recovery. InnoDB and the binary log commit
  together with an internal two-phase commit, so a transaction is in both or
  in neither.

The settings that make a commit durable on the lab primary:

```sql test
SELECT VARIABLE_NAME, VARIABLE_VALUE
  FROM performance_schema.global_variables
 WHERE VARIABLE_NAME IN ('innodb_flush_log_at_trx_commit', 'sync_binlog',
                         'innodb_doublewrite', 'innodb_redo_log_capacity',
                         'autocommit', 'transaction_isolation')
 ORDER BY VARIABLE_NAME;
```

```text
+--------------------------------+-----------------+
| VARIABLE_NAME                  | VARIABLE_VALUE  |
+--------------------------------+-----------------+
| autocommit                     | ON              |
| innodb_doublewrite             | ON              |
| innodb_flush_log_at_trx_commit | 1               |
| innodb_redo_log_capacity       | 268435456       |
| sync_binlog                    | 1               |
| transaction_isolation          | REPEATABLE-READ |
+--------------------------------+-----------------+
```

`innodb_flush_log_at_trx_commit = 1` writes and flushes the redo log at every
commit; `2` and `0` flush about once a second and can lose up to a second of
committed transactions in a crash or power loss
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_flush_log_at_trx_commit)).
`sync_binlog = 1` does the same for the binary log. Together they are the
durable setting; anything else is a trade of data for latency, and should be a
written-down decision.

## 2. Transaction boundaries: autocommit and implicit commits

With `autocommit = ON`, the default, every statement outside
`START TRANSACTION ... COMMIT` is its own transaction
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-autocommit-commit-rollback.html)).
Two traps follow from the rules.

**DDL commits for you.** Most DDL statements, such as `CREATE TABLE`,
`ALTER TABLE` and `TRUNCATE`, commit the current transaction before they run
([manual: statements that cause an implicit commit](https://dev.mysql.com/doc/refman/8.4/en/implicit-commit.html)).
A later `ROLLBACK` has nothing to undo:

```sql test
CREATE DATABASE lab;
CREATE TABLE lab.notes (id INT PRIMARY KEY, body VARCHAR(50));
START TRANSACTION;
INSERT INTO lab.notes VALUES (1, 'written inside a transaction');
CREATE TABLE lab.audit (id INT PRIMARY KEY);   -- implicit COMMIT here
ROLLBACK;
SELECT * FROM lab.notes;
DROP DATABASE lab;
```

```text
+----+------------------------------+
| id | body                         |
+----+------------------------------+
|  1 | written inside a transaction |
+----+------------------------------+
```

**`autocommit = 0` leaks transactions.** With autocommit off, the first
statement starts a transaction that stays open until the session commits.
Frameworks and connection pools that switch autocommit off, run a `SELECT`
and return the connection to the pool leave an open transaction behind: it
holds a read view, metadata locks and any row locks it took. You will see
what that costs in sections 4 and 8. `information_schema.INNODB_TRX` lists
every open InnoDB transaction
([manual](https://dev.mysql.com/doc/refman/8.4/en/information-schema-innodb-trx-table.html)):

```bash test
# A session switches autocommit off, reads one row, then sits idle for 6 s.
( echo "SET autocommit = 0; SELECT status FROM shop.orders WHERE id = 1;"
  sleep 6 ) | ./lab sql >/dev/null &
sleep 2
./lab sql --table -e "
  SELECT trx_mysql_thread_id AS pid, trx_state, trx_isolation_level,
         TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s
    FROM information_schema.INNODB_TRX"
wait
```

```text
+-----+-----------+---------------------+-------+
| pid | trx_state | trx_isolation_level | age_s |
+-----+-----------+---------------------+-------+
| 691 | RUNNING   | REPEATABLE READ     |     2 |
+-----+-----------+---------------------+-------+
```

The session ran one `SELECT` and is doing nothing, yet its transaction is
open. The `pid` (here 691) will differ on your lab.

## 3. Consistent reads, locking reads and isolation levels

InnoDB's default isolation level is REPEATABLE READ
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)).
What a `SELECT` returns depends on whether it is a *consistent read* or a
*locking read*:

- A plain `SELECT` is a **consistent read**: it reads a snapshot and takes no
  row locks. Under REPEATABLE READ the snapshot is taken at the transaction's
  first consistent read and reused until commit; under READ COMMITTED each
  statement takes a fresh one
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)).
- `SELECT ... FOR SHARE`, `SELECT ... FOR UPDATE`, `UPDATE` and `DELETE` are
  **locking reads**: they read the latest committed version and lock what
  they read
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-reads.html)).

The snapshot is built from undo records: when a row is newer than the
reader's *read view*, InnoDB follows the row's roll pointer into the undo log
and rebuilds the older version. That is **MVCC**, multi-version concurrency
control
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html)).

Watch it happen. Two readers, one per isolation level, read the same
inventory row twice, three seconds apart. In between, a third session takes
10 units off the stock and commits:

```bash test
out="$(mktemp -d)"
reader() { # reader <isolation level> <file>
  ./lab sql -N -e "
    SET SESSION TRANSACTION ISOLATION LEVEL $1;
    START TRANSACTION;
    SELECT '$1', 'first read   ', on_hand FROM shop.inventory
     WHERE product_id = 42 AND warehouse = 'TLL';
    DO SLEEP(3);
    SELECT '$1', 'second read  ', on_hand FROM shop.inventory
     WHERE product_id = 42 AND warehouse = 'TLL';
    SELECT '$1', 'locking read ', on_hand FROM shop.inventory
     WHERE product_id = 42 AND warehouse = 'TLL' FOR SHARE;
    COMMIT;" > "$2"
}
reader "REPEATABLE READ" "$out/rr" &
reader "READ COMMITTED" "$out/rc" &
sleep 1
./lab sql -e "UPDATE shop.inventory SET on_hand = on_hand - 10
               WHERE product_id = 42 AND warehouse = 'TLL'"
wait
cat "$out/rr" "$out/rc"
# Put the stock back.
./lab sql -e "UPDATE shop.inventory SET on_hand = on_hand + 10
               WHERE product_id = 42 AND warehouse = 'TLL'"
rm -r "$out"
```

```text
REPEATABLE READ	first read   	443
REPEATABLE READ	second read  	443
REPEATABLE READ	locking read 	433
READ COMMITTED	first read   	443
READ COMMITTED	second read  	433
READ COMMITTED	locking read 	433
```

Under REPEATABLE READ the second plain read still sees 443, even though 433
was committed a second earlier. The locking read in the same transaction sees
433. Code that reads a value with a plain `SELECT` and then writes based on
it is working from a snapshot that may already be stale: read with
`FOR UPDATE` when you are going to write.

## 4. Purge and the history list length

Undo records cannot be thrown away while any read view might still need them.
InnoDB's **purge** threads remove them, and the rows marked for deletion,
once no open read view is older than the change
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)).
The **history list length** counts the committed transactions whose undo logs
have not been freed yet.

One transaction that keeps a read view open holds back purge for the whole
server, not just for the tables it read. Here a session takes a snapshot and
idles while 1 000 small transactions commit elsewhere:

```bash test
status() { ./lab sql -e "SHOW ENGINE INNODB STATUS\G" \
           | grep -E "^(Trx id counter|Purge done|History list length)"; }
# A session opens a snapshot and stays idle for 8 seconds.
( echo "START TRANSACTION WITH CONSISTENT SNAPSHOT;"; sleep 8 ) \
  | ./lab sql >/dev/null &
sleep 1
# 1 000 committed transactions: +1 then -1, so the data ends unchanged.
for _ in $(seq 500); do
  echo "UPDATE shop.inventory SET reserved = reserved + 1 WHERE product_id = 1 AND warehouse = 'TLL';"
  echo "UPDATE shop.inventory SET reserved = reserved - 1 WHERE product_id = 1 AND warehouse = 'TLL';"
done | ./lab sql
echo "-- while the snapshot is open"; status
wait
sleep 2
echo "-- after it ended"; status
```

```text
-- while the snapshot is open
Trx id counter 8966
Purge done for trx's n:o < 6911 undo n:o < 0 state: running but idle
History list length 1002
-- after it ended
Trx id counter 8967
Purge done for trx's n:o < 8966 undo n:o < 0 state: running but idle
History list length 1002
```

Your numbers will differ; the pattern will not. While the snapshot is open,
`Purge done for trx's n:o` stops at the old transaction's number while the
`Trx id counter` moves on: purge cannot proceed past it. When the session
ends, purge catches up within a second or two. The history list length
drops later, because the purge system frees rollback segments, and with them
the history list entries, only once every `innodb_purge_rseg_truncate_frequency`
(128) times it runs
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_purge_rseg_truncate_frequency)).
On an idle lab it may stay at its value for a while; on a busy server, watch
its trend, not one sample. The same value is in
`information_schema.INNODB_METRICS` as `trx_rseg_history_len`, which is what
monitoring usually scrapes.

What a growing history list costs:

- consistent reads walk longer version chains in the undo log to rebuild old
  row versions, so read queries get slower for everyone;
- undo tablespaces grow; they are truncated only after purge has freed them
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-tablespaces.html));
- delete-marked rows and old secondary index entries stay in the indexes.

The remedy is the same every time: find the oldest transaction in
`INNODB_TRX` and get it committed or ended. Section 6 shows how.

<!-- founder-review: a first-hand story of a forgotten transaction (an
analytics client, a stuck worker, an ORM with autocommit=0) driving the
history list into the millions would help here -->

## 5. Row locks: record, gap, next-key and insert intention

InnoDB locks **index records**, not rows in the abstract. A locking read, an
`UPDATE` or a `DELETE` locks every index record its scan touches, whether or
not the row matches the rest of the `WHERE` clause
([manual: locks set by different statements](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html)).
The lock types
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)):

| Lock | `data_locks.LOCK_MODE` | Protects |
|---|---|---|
| Record lock | `X,REC_NOT_GAP` | one index record |
| Gap lock | `X,GAP` | the gap before a record, not the record |
| Next-key lock | `X` | the record plus the gap before it |
| Insert intention | `X,GAP,INSERT_INTENTION` | an INSERT waiting for a gap |

Shared (`S`) variants exist for `FOR SHARE`. At table level, each
transaction first takes an intention lock (`IX` or `IS`), which only
conflicts with whole-table locks.

`performance_schema.data_locks` shows every lock InnoDB holds, including your
own session's
([manual](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-data-locks-table.html)).
Three lookups, three shapes:

```sql test
-- 1. A unique lookup on the primary key: one record lock.
START TRANSACTION;
SELECT on_hand FROM shop.inventory
 WHERE product_id = 42 AND warehouse = 'TLL' FOR UPDATE;
SELECT INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_DATA
  FROM performance_schema.data_locks
 WHERE OBJECT_NAME = 'inventory' ORDER BY INDEX_NAME, LOCK_DATA;
ROLLBACK;

-- 2. A non-unique secondary index: next-key locks plus a gap lock.
START TRANSACTION;
SELECT id, status FROM shop.orders WHERE customer_id = 15002 FOR UPDATE;
SELECT INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_DATA
  FROM performance_schema.data_locks
 WHERE OBJECT_NAME = 'orders' ORDER BY INDEX_NAME, LOCK_DATA;
ROLLBACK;

-- 3. A range on the primary key.
START TRANSACTION;
SELECT id FROM shop.orders WHERE id BETWEEN 100 AND 102 FOR UPDATE;
SELECT INDEX_NAME, LOCK_TYPE, LOCK_MODE, LOCK_DATA
  FROM performance_schema.data_locks
 WHERE OBJECT_NAME = 'orders' ORDER BY INDEX_NAME, LOCK_DATA;
ROLLBACK;
```

```text
+---------+
| on_hand |
+---------+
|     443 |
+---------+
+------------+-----------+---------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_DATA |
+------------+-----------+---------------+-----------+
| NULL       | TABLE     | IX            | NULL      |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | 42, 'TLL' |
+------------+-----------+---------------+-----------+
+--------+-----------+
| id     | status    |
+--------+-----------+
|  62567 | pending   |
| 117638 | delivered |
+--------+-----------+
+---------------------+-----------+---------------+---------------+
| INDEX_NAME          | LOCK_TYPE | LOCK_MODE     | LOCK_DATA     |
+---------------------+-----------+---------------+---------------+
| NULL                | TABLE     | IX            | NULL          |
| idx_orders_customer | RECORD    | X             | 15002, 117638 |
| idx_orders_customer | RECORD    | X             | 15002, 62567  |
| idx_orders_customer | RECORD    | X,GAP         | 15003, 2672   |
| PRIMARY             | RECORD    | X,REC_NOT_GAP | 117638        |
| PRIMARY             | RECORD    | X,REC_NOT_GAP | 62567         |
+---------------------+-----------+---------------+---------------+
+-----+
| id  |
+-----+
| 100 |
| 101 |
| 102 |
+-----+
+------------+-----------+---------------+-----------+
| INDEX_NAME | LOCK_TYPE | LOCK_MODE     | LOCK_DATA |
+------------+-----------+---------------+-----------+
| NULL       | TABLE     | IX            | NULL      |
| PRIMARY    | RECORD    | X,REC_NOT_GAP | 100       |
| PRIMARY    | RECORD    | X             | 101       |
| PRIMARY    | RECORD    | X             | 102       |
+------------+-----------+---------------+-----------+
```

Read the second result closely. The secondary index entries carry the primary
key (`15002, 62567`), so `LOCK_DATA` shows both. InnoDB took next-key locks
on customer 15002's two entries, record locks on the two clustered index rows
they point to, and a gap lock on the first entry of customer 15003. That gap
lock is what makes REPEATABLE READ repeatable for locking reads: no other
transaction can insert a new order for customer 15002 until this one ends.

The third result is a range on a unique key: a plain record lock on 100,
where the range starts, and next-key locks on 101 and 102, which also cover
the gaps between them. Nothing beyond 102 is locked.

A blocked INSERT waits with an **insert intention** lock:

```bash test
# Session A: lock customer 15002's orders, hold for 6 s, roll back.
./lab sql -e "START TRANSACTION;
  SELECT id FROM shop.orders WHERE customer_id = 15002 FOR UPDATE;
  DO SLEEP(6); ROLLBACK;" >/dev/null &
sleep 1
# Session B: a new order for that customer. It gives up after 3 s.
./lab sql -e "SET SESSION innodb_lock_wait_timeout = 3;
  INSERT INTO shop.orders (customer_id, status, total_cents, created_at, updated_at)
  VALUES (15002, 'pending', 1000, NOW(), NOW())" >/dev/null 2>&1 &
sleep 1
./lab sql --table -e "
  SELECT INDEX_NAME, LOCK_MODE, LOCK_STATUS, LOCK_DATA
    FROM performance_schema.data_locks
   WHERE OBJECT_NAME = 'orders' AND LOCK_STATUS = 'WAITING'"
wait
# The failed INSERT still used up an AUTO_INCREMENT value. Put the counter
# back to MAX(id) + 1 so the lab stays at its baseline.
./lab sql -e "ALTER TABLE shop.orders AUTO_INCREMENT = 1"
```

```text
+---------------------+------------------------+-------------+-------------+
| INDEX_NAME          | LOCK_MODE              | LOCK_STATUS | LOCK_DATA   |
+---------------------+------------------------+-------------+-------------+
| idx_orders_customer | X,GAP,INSERT_INTENTION | WAITING     | 15003, 2672 |
+---------------------+------------------------+-------------+-------------+
```

Two lessons for production:

- **The index decides what gets locked.** An `UPDATE ... WHERE` on an
  unindexed column scans, and therefore locks, every row of the table.
  Indexing is a locking concern as well as a speed concern (Module 4).
- **READ COMMITTED takes far fewer gap locks.** InnoDB uses gap locking under
  READ COMMITTED only for foreign key and duplicate key checks
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-transaction-isolation-levels.html)).
  Some applications switch to it to reduce lock contention, accepting
  non-repeatable reads.

## 6. Lock waits and timeouts

A transaction that needs a lock someone else holds waits up to
`innodb_lock_wait_timeout` seconds (50 by default; 20 in this lab) and then
fails with error 1205
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html#sysvar_innodb_lock_wait_timeout)).
What happens next surprises many developers: by default InnoDB rolls back
**only the statement that timed out**, not the transaction
(`innodb_rollback_on_timeout = OFF`). The transaction stays open with its
earlier changes and locks, and the application must decide to retry or roll
back:

```bash test
# Session A: lock product 7 in TLL and sit idle for 6 s.
( echo "START TRANSACTION;
        UPDATE shop.inventory SET reserved = reserved + 1
         WHERE product_id = 7 AND warehouse = 'TLL';"
  sleep 6 ) | ./lab sql &
sleep 1
# Session B: the first UPDATE works, the second waits 3 s and fails.
./lab sql --force --table 2>&1 <<'SQL' || true
SET SESSION innodb_lock_wait_timeout = 3;
START TRANSACTION;
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 7 AND warehouse = 'HEL';
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 7 AND warehouse = 'TLL';
SELECT warehouse, reserved FROM shop.inventory WHERE product_id = 7;
SELECT trx_state, trx_rows_modified FROM information_schema.INNODB_TRX
 WHERE trx_mysql_thread_id = CONNECTION_ID();
ROLLBACK;
SQL
wait
```

```text
ERROR 1205 (HY000) at line 5: Lock wait timeout exceeded; try restarting transaction
+-----------+----------+
| warehouse | reserved |
+-----------+----------+
| HEL       |        1 |
| RIX       |        0 |
| TLL       |        0 |
+-----------+----------+
+-----------+-------------------+
| trx_state | trx_rows_modified |
+-----------+-------------------+
| RUNNING   |                 1 |
+-----------+-------------------+
```

After the timeout, session B's transaction is still `RUNNING` with the HEL
change in it. An application that catches error 1205, logs it and carries on
using the connection will commit half a transaction.

### Finding the blocker

When requests time out on locks, the question is always the same: *who holds
the lock, and what is that session doing?* Three sources answer it:

- `performance_schema.data_lock_waits`: one row per waiting lock request, with
  the blocking lock
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-data-lock-waits-table.html));
- `sys.innodb_lock_waits`: the same joined to the transactions and processlist
  ids, with ready-made `KILL` statements
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/sys-innodb-lock-waits.html));
- `information_schema.INNODB_TRX`: every open transaction, its age, rows
  locked and rows modified.

The block below reproduces the most common production case. Session A
reserves stock and goes quiet without committing; session B waits for one of
the rows:

```bash test
# Session A: reserve stock for product 42, then go quiet without committing.
( echo "START TRANSACTION;
        UPDATE shop.inventory SET reserved = reserved + 5 WHERE product_id = 42;"
  sleep 15 ) | ./lab sql >/dev/null 2>&1 &
sleep 1
# Session B: wants one of those rows (and rolls back once it gets it).
./lab sql -e "START TRANSACTION;
  UPDATE shop.inventory SET reserved = reserved + 1
   WHERE product_id = 42 AND warehouse = 'TLL';
  ROLLBACK;" >/dev/null 2>&1 &
sleep 2
./lab sql --table -e "
  SELECT waiting_pid, waiting_query, blocking_pid, blocking_query,
         wait_age_secs, sql_kill_blocking_connection
    FROM sys.innodb_lock_waits\G
  SELECT PROCESSLIST_ID AS id, PROCESSLIST_COMMAND AS command,
         PROCESSLIST_TIME AS time, PROCESSLIST_STATE AS state
    FROM performance_schema.threads
   WHERE PROCESSLIST_ID IN (SELECT blocking_pid FROM sys.innodb_lock_waits);
  SELECT trx_mysql_thread_id AS pid, trx_state, trx_rows_locked,
         trx_rows_modified, TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_s
    FROM information_schema.INNODB_TRX ORDER BY trx_started;"
# End the blocker's connection: its transaction rolls back, B gets the lock.
blocker="$(./lab sql -N -e "SELECT DISTINCT blocking_pid FROM sys.innodb_lock_waits")"
./lab sql -e "KILL $blocker"
sleep 1
./lab sql --table -e "SELECT COUNT(*) AS lock_waits FROM performance_schema.data_lock_waits"
wait
```

```text
*************************** 1. row ***************************
                 waiting_pid: 719
               waiting_query: UPDATE shop.inventory SET rese ... _id = 42 AND warehouse = 'TLL'
                blocking_pid: 718
              blocking_query: NULL
               wait_age_secs: 3
sql_kill_blocking_connection: KILL 718
+------+---------+------+-------+
| id   | command | time | state |
+------+---------+------+-------+
|  718 | Sleep   |    4 | NULL  |
+------+---------+------+-------+
+-----+-----------+-----------------+-------------------+-------+
| pid | trx_state | trx_rows_locked | trx_rows_modified | age_s |
+-----+-----------+-----------------+-------------------+-------+
| 718 | RUNNING   |               4 |                 3 |     4 |
| 719 | LOCK WAIT |               1 |                 0 |     3 |
+-----+-----------+-----------------+-------------------+-------+
+------------+
| lock_waits |
+------------+
|          0 |
+------------+
```

How to read it:

- `blocking_query: NULL` and `command: Sleep` mean the blocker is **idle in a
  transaction**: connected, doing nothing, still holding its locks. The query
  that took them finished long ago, so no query log line points at it.
  `trx_rows_modified: 3` says it has uncommitted changes.
- `KILL QUERY <id>` would do nothing here: there is no running statement to
  stop. `KILL <id>` (`KILL CONNECTION`) ends the session and InnoDB rolls back
  its transaction
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/kill.html)).
- Killing loses the blocker's uncommitted work. Before you kill in
  production, look at the account, host and age: it may be a migration, a
  batch job or a person's console. Then find out why the application left a
  transaction open, or it will happen again.
- A rollback has to undo every change the transaction made. A killed
  transaction that modified millions of rows shows `trx_state = ROLLING BACK`
  in `INNODB_TRX` and keeps its locks until the rollback finishes.

When several sessions block each other in a chain, follow `blocking_pid`
until you reach a session that is not itself waiting. That is the root
blocker; killing the ones in the middle only shuffles the queue.

<!-- founder-review: a real incident where the root blocker was an idle
console session or a stuck job would make the "look before you KILL" advice
concrete -->

## 7. Deadlocks

A deadlock is a cycle: A waits for B while B waits for A. Unlike a lock wait,
it cannot resolve itself, so InnoDB detects it immediately
(`innodb_deadlock_detect = ON`) and rolls back one transaction, preferring
the smaller one, measured by rows inserted, updated or deleted
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlock-detection.html)).
The victim gets error 1213; the other transaction carries on.

Two sessions touch the same two products in opposite order:

```bash test
# Session A: reserve product 7 everywhere, pause, then touch product 8 in TLL.
./lab sql --force <<'SQL' >/dev/null 2>&1 &
START TRANSACTION;
UPDATE shop.inventory SET reserved = reserved + 1 WHERE product_id = 7;
DO SLEEP(2);
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 8 AND warehouse = 'TLL';
DO SLEEP(1);
ROLLBACK;
SQL
sleep 1
# Session B: product 8 first, then product 7.
./lab sql --force <<'SQL' 2>&1 || true
START TRANSACTION;
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 8 AND warehouse = 'TLL';
DO SLEEP(2);
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 7 AND warehouse = 'TLL';
ROLLBACK;
SQL
wait
# The most recent deadlock, from the InnoDB monitor output.
./lab sql -e "SHOW ENGINE INNODB STATUS\G" \
  | sed -n '/^LATEST DETECTED DEADLOCK/,/^TRANSACTIONS/p' \
  | grep -vE '^ [0-9]+: len|^Record lock, heap no|^$'
```

```text
ERROR 1213 (40001) at line 5: Deadlock found when trying to get lock; try restarting transaction
LATEST DETECTED DEADLOCK
------------------------
2026-10-13 10:45:30 281472678096640
*** (1) TRANSACTION:
TRANSACTION 8986, ACTIVE 3 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 4 lock struct(s), heap size 1128, 5 row lock(s), undo log entries 3
MySQL thread id 729, OS thread handle 281472632471296, query id 6033 localhost root updating
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 8 AND warehouse = 'TLL'
*** (1) HOLDS THE LOCK(S):
RECORD LOCKS space id 4 page no 5 n bits 456 index PRIMARY of table `shop`.`inventory` trx id 8986 lock_mode X
*** (1) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 4 page no 5 n bits 456 index PRIMARY of table `shop`.`inventory` trx id 8986 lock_mode X locks rec but not gap waiting
*** (2) TRANSACTION:
TRANSACTION 8987, ACTIVE 2 sec starting index read
mysql tables in use 1, locked 1
LOCK WAIT 3 lock struct(s), heap size 1128, 2 row lock(s), undo log entries 1
MySQL thread id 730, OS thread handle 281472635825920, query id 6034 localhost root updating
UPDATE shop.inventory SET reserved = reserved + 1
 WHERE product_id = 7 AND warehouse = 'TLL'
*** (2) HOLDS THE LOCK(S):
RECORD LOCKS space id 4 page no 5 n bits 456 index PRIMARY of table `shop`.`inventory` trx id 8987 lock_mode X locks rec but not gap
*** (2) WAITING FOR THIS LOCK TO BE GRANTED:
RECORD LOCKS space id 4 page no 5 n bits 456 index PRIMARY of table `shop`.`inventory` trx id 8987 lock_mode X locks rec but not gap waiting
*** WE ROLL BACK TRANSACTION (2)
------------
TRANSACTIONS
```

The filter drops the hex dumps of the locked records; read them in the full
output when you need the exact key values. Transaction (1) held three rows
(`undo log entries 3`), transaction (2) one, so InnoDB rolled back (2).
Ids, timestamps and thread handles differ on every run.

`SHOW ENGINE INNODB STATUS` keeps only the latest deadlock
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-standard-monitor.html)).
With `innodb_print_all_deadlocks = ON`, as in this lab, every deadlock also
goes to the error log, which you can query from SQL:

```sql test
SELECT COUNT(*) AS deadlock_report_lines
  FROM performance_schema.error_log
 WHERE SUBSYSTEM = 'InnoDB' AND DATA LIKE '%WE ROLL BACK TRANSACTION%';
SELECT NAME, COUNT FROM information_schema.INNODB_METRICS
 WHERE NAME IN ('lock_deadlocks', 'lock_timeouts');
```

```text
+-----------------------+
| deadlock_report_lines |
+-----------------------+
|                     2 |
+-----------------------+
+----------------+-------+
| NAME           | COUNT |
+----------------+-------+
| lock_deadlocks |     2 |
| lock_timeouts  |     9 |
+----------------+-------+
```

The counts grow as you rerun the examples. Graph `lock_deadlocks` and
`lock_timeouts`; a step change after a deploy points at the new code.

What to do about deadlocks
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks-handling.html)):

- **Retry.** A deadlock victim's transaction was rolled back completely; the
  application should retry it. Occasional deadlocks are normal in a busy
  OLTP system.
- **Touch rows in a consistent order.** Both sessions above would have queued
  instead of deadlocking if they had locked product 7 before product 8.
- **Keep transactions short and index the `WHERE` clauses**, so fewer records
  are locked for less time.
- Do not switch off `innodb_deadlock_detect` to "fix" deadlocks. Without
  detection, the cycle waits out `innodb_lock_wait_timeout` instead.

## 8. Metadata locks: DDL behind an open transaction

Row locks belong to InnoDB. **Metadata locks** (MDL) belong to the server:
every statement that uses a table takes a shared metadata lock on it, and a
transaction keeps those until it ends. DDL needs an exclusive one
([manual](https://dev.mysql.com/doc/refman/8.4/en/metadata-locking.html)).
Three facts make this one of the most common self-inflicted outages:

1. An idle transaction that once read a table holds a shared metadata lock on
   it, so `ALTER TABLE` on that table waits.
2. A pending exclusive request has priority over new shared requests. Every
   query on the table that arrives after the `ALTER` queues behind it, even a
   plain `SELECT`.
3. `lock_wait_timeout`, the metadata lock timeout, defaults to 31 536 000
   seconds: one year
   ([manual](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_lock_wait_timeout)).
   A blocked `ALTER` does not give up.

Even "online" DDL (`ALGORITHM=INPLACE` or `INSTANT`) needs the exclusive
metadata lock briefly at the start and at the end
([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-performance.html)).

The safe habit: run DDL in a session with a short `lock_wait_timeout`, so a
blocked `ALTER` fails after a few seconds and the queue behind it drains,
instead of taking the table down. Here session B does exactly that, while a
transaction in session A holds a lock on `shop.products`:

```bash test
out="$(mktemp)"
# Session A: a transaction that read shop.products and then went idle.
( echo "START TRANSACTION; SELECT COUNT(*) FROM shop.products;"; sleep 10 ) \
  | ./lab sql >/dev/null 2>&1 &
sleep 1
# Session B: a schema change, allowed to wait at most 6 s for its lock.
./lab sql -e "SET SESSION lock_wait_timeout = 6;
              ALTER TABLE shop.products ENGINE = InnoDB" >"$out" 2>&1 &
sleep 1
# Session C: an ordinary read that arrives after the ALTER.
./lab sql -e "SELECT COUNT(*) FROM shop.products" >/dev/null 2>&1 &
sleep 1
./lab sql --table -e "
  SELECT PROCESSLIST_ID AS id, PROCESSLIST_COMMAND AS cmd,
         PROCESSLIST_STATE AS state, LEFT(PROCESSLIST_INFO, 34) AS info
    FROM performance_schema.threads
   WHERE PROCESSLIST_USER = 'root' AND PROCESSLIST_ID <> CONNECTION_ID();
  SELECT LOCK_TYPE, LOCK_DURATION, LOCK_STATUS, OWNER_THREAD_ID
    FROM performance_schema.metadata_locks
   WHERE OBJECT_SCHEMA = 'shop' AND OBJECT_NAME = 'products';
  SELECT waiting_pid, waiting_lock_type, blocking_pid, blocking_lock_type
    FROM sys.schema_table_lock_waits;"
wait
cat "$out"; rm -f "$out"
```

```text
+------+-------+---------------------------------+------------------------------------+
| id   | cmd   | state                           | info                               |
+------+-------+---------------------------------+------------------------------------+
|  734 | Sleep | NULL                            | NULL                               |
|  736 | Query | Waiting for table metadata lock | ALTER TABLE shop.products ENGINE = |
|  737 | Query | Waiting for table metadata lock | SELECT COUNT(*) FROM shop.products |
+------+-------+---------------------------------+------------------------------------+
+-------------------+---------------+-------------+-----------------+
| LOCK_TYPE         | LOCK_DURATION | LOCK_STATUS | OWNER_THREAD_ID |
+-------------------+---------------+-------------+-----------------+
| SHARED_READ       | TRANSACTION   | GRANTED     |             866 |
| SHARED_UPGRADABLE | TRANSACTION   | GRANTED     |             868 |
| EXCLUSIVE         | TRANSACTION   | PENDING     |             868 |
| SHARED_READ       | TRANSACTION   | PENDING     |             869 |
+-------------------+---------------+-------------+-----------------+
+-------------+-------------------+--------------+--------------------+
| waiting_pid | waiting_lock_type | blocking_pid | blocking_lock_type |
+-------------+-------------------+--------------+--------------------+
|         736 | EXCLUSIVE         |          734 | SHARED_READ        |
|         737 | SHARED_READ       |          734 | SHARED_READ        |
|         736 | EXCLUSIVE         |          736 | SHARED_UPGRADABLE  |
|         737 | SHARED_READ       |          736 | SHARED_UPGRADABLE  |
+-------------+-------------------+--------------+--------------------+
ERROR 1205 (HY000) at line 2: Lock wait timeout exceeded; try restarting transaction
```

Reading it:

- `performance_schema.metadata_locks` is the ground truth: thread 866
  (session A) holds `SHARED_READ`; the `ALTER` holds `SHARED_UPGRADABLE` and
  waits for `EXCLUSIVE`; the `SELECT` waits for `SHARED_READ`, which is only
  incompatible with the pending `EXCLUSIVE`
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-metadata-locks-table.html)).
  `OWNER_THREAD_ID` is the Performance Schema thread id, not the processlist
  id; `performance_schema.threads` maps one to the other.
- `sys.schema_table_lock_waits` pairs every waiter with every holder on the
  table, so it lists the waiting `ALTER` itself as a blocker
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/sys-schema-table-lock-waits.html)).
  The root blocker is the `blocking_pid` that never appears as a
  `waiting_pid`: here 734, the idle session.
- The `ALTER` gave up after 6 seconds with error 1205, the queue drained, and
  nothing was changed. Retry it later, or end the idle transaction first.
  Without the short timeout, the `SELECT` would still be waiting.

Schema-change tools such as `gh-ost` and `pt-online-schema-change` exist
largely because of this; they still need a short metadata lock to swap
tables, and their documentation covers how they bound it.

## Common mistakes and troubleshooting

| Symptom | Likely cause | Look at |
|---|---|---|
| Error 1205 on simple updates | Idle transaction holding row locks | `sys.innodb_lock_waits` |
| Queries on one table hang, CPU idle | `ALTER` queued behind an open trx | `sys.schema_table_lock_waits` |
| Reads slow down over hours | Long transaction, history list grows | `INNODB_TRX` by age |
| Error 1213 after a deploy | New code locks rows in another order | `LATEST DETECTED DEADLOCK` |

- **`KILL QUERY` on an idle blocker.** It returns OK and changes nothing. Use
  `KILL <id>` for a session in `Sleep` with an open transaction.
- **Killing the waiters instead of the blocker.** The queue refills on the next
  request. Follow `blocking_pid` to the root.
- **Treating 1205 as fatal for the transaction.** Only the statement was
  rolled back; roll back the transaction yourself before you retry.
- **Running `ALTER TABLE` with the default `lock_wait_timeout`.** Set it to a
  few seconds in the migration session and retry on failure.
- **Not looking at the oldest transaction.** Make
  `SELECT ... FROM information_schema.INNODB_TRX ORDER BY trx_started LIMIT 5`
  a habit in every incident; Module 9 builds on it.
- **Assuming `SELECT` never blocks.** A plain `SELECT` takes no row locks, but
  it does take a metadata lock, and it waits behind a pending `ALTER`.

## Further reading

- [InnoDB locking and transaction model](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking-transaction-model.html)
- [InnoDB locking](https://dev.mysql.com/doc/refman/8.4/en/innodb-locking.html)
  and [locks set by different SQL statements](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html)
- [Deadlocks in InnoDB](https://dev.mysql.com/doc/refman/8.4/en/innodb-deadlocks.html)
- [Metadata locking](https://dev.mysql.com/doc/refman/8.4/en/metadata-locking.html)
- [Using InnoDB transaction and locking information](https://dev.mysql.com/doc/refman/8.4/en/innodb-information-schema-examples.html)
- [Purge configuration](https://dev.mysql.com/doc/refman/8.4/en/innodb-purge-configuration.html)

## Next

Do the [exercises](exercise.md): two incidents from the lab, one with row
locks and one with metadata locks. Then test yourself with the
[quiz](quiz.md). Module 4 turns to the other half of "who locks what":
indexes and execution plans.
