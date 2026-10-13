# Module 1 — Database architecture and MySQL internals

`time: ~60 min` · `lab: ./lab scenario setup 01-architecture-tour` · `level: fundamentals`

Every production question about MySQL eventually becomes a question about
one of its parts. "Why is this connection slow?" is about a thread. "Why did
the disk fill up?" is about a tablespace or the binary log. "Will we lose
data if the host dies?" is about the redo log, the binary log and how the
two agree. This module maps those parts onto the running lab server so that
later modules — locking, backups, replication, incidents — have something
concrete to hang on.

## Learning objectives

By the end of this module you can:

- explain how MySQL turns a client connection into a server thread, and find
  that thread from SQL and from the operating system;
- separate the SQL layer (parser, optimizer, executor) from the storage
  engine, and see the boundary between them in status counters;
- name InnoDB's in-memory structures and say which of them are switched off
  by default in MySQL 8.4;
- find every InnoDB file in the data directory and say what it is for;
- explain why MySQL keeps both a redo log and a binary log, and what each
  does during crash recovery;
- choose between `information_schema`, `performance_schema` and `sys` for a
  given question.

## Prerequisites

- The lab is running: `./lab up` (see the course README).
- You can run SQL and shell commands. All commands run from the `labs/`
  directory.

`./lab sql` opens a MySQL shell as root on the primary. `./lab shell` opens a
bash shell inside the primary's container. To run a single command in a
container without an interactive shell, use `./lab exec <service> <command>`,
for example `./lab exec primary ls /var/lib/mysql`. It is
`docker compose exec -T` for this lab's project; where a command needs an
extra option such as `-e` (an environment variable) or `-d` (run in the
background), the course calls `docker compose exec` directly, which also works
from `labs/`.

## One process, many threads

MySQL is a single process, `mysqld`. It does not fork per client, as
PostgreSQL does. Inside the process there are two kinds of thread:

- **background threads**: InnoDB I/O, page cleaners, purge, the redo log
  writer and flusher, the event scheduler;
- **foreground threads**: one per client connection.

With the default `thread_handling = one-thread-per-connection`, each client
connection gets a dedicated OS thread that authenticates it and then runs
every statement it sends. When the client disconnects, the thread goes back
to a **thread cache** (up to `thread_cache_size` threads) so the next
connection can reuse it instead of creating a new one
([Connection Interfaces](https://dev.mysql.com/doc/refman/8.4/en/connection-interfaces.html)).
The thread pool that replaces this model is a MySQL Enterprise feature
([MySQL Enterprise Thread Pool](https://dev.mysql.com/doc/refman/8.4/en/thread-pool.html)).

`performance_schema.threads` lists every thread, with the operating system's
id for it in `THREAD_OS_ID`:

```sql test
SELECT TYPE, COUNT(*) AS threads
FROM performance_schema.threads
GROUP BY TYPE;

SELECT PROCESSLIST_ID, PROCESSLIST_USER, PROCESSLIST_COMMAND, THREAD_OS_ID
FROM performance_schema.threads
WHERE TYPE = 'FOREGROUND';
```

```text
+------------+---------+
| TYPE       | threads |
+------------+---------+
| BACKGROUND |      41 |
| FOREGROUND |       4 |
+------------+---------+
+----------------+------------------+---------------------+--------------+
| PROCESSLIST_ID | PROCESSLIST_USER | PROCESSLIST_COMMAND | THREAD_OS_ID |
+----------------+------------------+---------------------+--------------+
|              5 | event_scheduler  | Daemon              |          130 |
|              7 | NULL             | Daemon              |          134 |
|              8 | repl             | Binlog Dump GTID    |          135 |
|             64 | root             | Query               |          142 |
+----------------+------------------+---------------------+--------------+
```

`repl` is the replica, connected to the primary to stream the binary log.
Its thread is a real Linux thread inside `mysqld` (PID 1 in the container),
and `ps -L` shows it under the same id. Your ids will differ:

```bash test
tid=$(./lab sql -N -e "SELECT THREAD_OS_ID FROM performance_schema.threads
                        WHERE PROCESSLIST_COMMAND LIKE 'Binlog Dump%'")
echo "the replica's connection runs on OS thread $tid"
./lab exec primary ps -L -o pid,lwp,comm -p 1 \
  | awk -v t="$tid" 'NR == 1 || $2 == t'
```

```text
the replica's connection runs on OS thread 135
    PID     LWP COMMAND
      1     135 connection
```

This is the bridge you need during an incident: `top -H` on the host shows
one thread burning a CPU, and `THREAD_OS_ID` tells you which connection and
which query that is.

The thread cache is visible in the status counters. `Connections` counts
connection attempts; `Threads_created` counts threads the server had to
create. Open ten short connections and compare:

```bash test
./lab sql --table -e "SHOW GLOBAL STATUS
  WHERE Variable_name IN ('Connections', 'Threads_created', 'Threads_cached')"
for i in 1 2 3 4 5 6 7 8 9 10; do ./lab sql -e "SELECT 1" >/dev/null; done
./lab sql --table -e "SHOW GLOBAL STATUS
  WHERE Variable_name IN ('Connections', 'Threads_created', 'Threads_cached')"
```

```text
+-----------------+-------+
| Variable_name   | Value |
+-----------------+-------+
| Connections     | 26    |
| Threads_cached  | 0     |
| Threads_created | 2     |
+-----------------+-------+
...
| Connections     | 37    |
| Threads_cached  | 1     |
| Threads_created | 3     |
```

Eleven connections, one new thread. On a busy server, a `Threads_created`
that climbs steadily alongside `Connections` means the cache is too small
for the connection churn. Each thread also carries its own stack and
per-session buffers, which is why `max_connections` is a memory decision as
well as a limit.

## The SQL layer and the storage engine

A statement passes through two layers
([Overview of MySQL Storage Engine Architecture](https://dev.mysql.com/doc/refman/8.4/en/pluggable-storage-overview.html)):

1. The **SQL layer** — parser, optimizer and executor — is the same whatever
   the storage engine. The parser checks syntax and builds a parse tree, the
   optimizer chooses a plan (index, join order), and the executor runs it.
2. The **storage engine** stores and fetches rows. The executor talks to it
   only through the **handler API**: "position on this index key", "give me
   the next row", "write this row".

Engines are plugins. InnoDB is the default and the only one this course
uses for data:

```sql test
SELECT ENGINE, SUPPORT, TRANSACTIONS
FROM information_schema.ENGINES
WHERE SUPPORT IN ('YES', 'DEFAULT')
ORDER BY ENGINE;
```

```text
+--------------------+---------+--------------+
| ENGINE             | SUPPORT | TRANSACTIONS |
+--------------------+---------+--------------+
| ARCHIVE            | YES     | NO           |
| BLACKHOLE          | YES     | NO           |
| CSV                | YES     | NO           |
| InnoDB             | DEFAULT | YES          |
| MEMORY             | YES     | NO           |
| MRG_MYISAM         | YES     | NO           |
| MyISAM             | YES     | NO           |
| PERFORMANCE_SCHEMA | YES     | NO           |
+--------------------+---------+--------------+
```

You can watch the boundary. `EXPLAIN` shows the optimizer's plan; the
`Handler_read_*` session counters count the calls the executor made into the
engine. Run the same kind of query with and without a usable index:

```sql test
EXPLAIN FORMAT=TREE
SELECT COUNT(*) FROM shop.orders WHERE customer_id = 42;

FLUSH STATUS;
SELECT COUNT(*) FROM shop.orders WHERE customer_id = 42;
SHOW SESSION STATUS WHERE Variable_name LIKE 'Handler_read%' AND Value > 0;

FLUSH STATUS;
SELECT COUNT(*) FROM shop.orders WHERE total_cents = 4242;
SHOW SESSION STATUS WHERE Variable_name LIKE 'Handler_read%' AND Value > 0;
```

```text
-> Aggregate: count(0)  (cost=36.3 rows=1)
    -> Covering index lookup on orders using idx_orders_customer (customer_id=42)
...
| COUNT(*) |
|      180 |
| Handler_read_key  | 1     |
| Handler_read_next | 180   |
...
| COUNT(*) |
|        0 |
| Handler_read_first    | 1      |
| Handler_read_key      | 1      |
| Handler_read_rnd_next | 200001 |
```

The indexed query is one key lookup plus 180 "next" calls. The unindexed one
asks InnoDB for every row in the table, 200 001 calls, to return nothing.
Module 4 builds on exactly this.

## InnoDB in memory

InnoDB keeps four structures in memory
([InnoDB In-Memory Structures](https://dev.mysql.com/doc/refman/8.4/en/innodb-in-memory-structures.html)):

| Structure | What it holds | In this lab |
|---|---|---|
| Buffer pool | Data and index pages (16 KiB each) | 256 MiB, 1 instance |
| Change buffer | Deferred secondary-index changes | Off (`none`) |
| Adaptive hash index | Hash lookups built over hot B-tree pages | Off |
| Log buffer | Redo records not yet written to disk | 64 MiB |

```sql test
SELECT @@innodb_buffer_pool_size / 1024 / 1024 AS buffer_pool_mb,
       @@innodb_buffer_pool_instances          AS bp_instances,
       @@innodb_page_size                      AS page_size,
       @@innodb_change_buffering               AS change_buffering,
       @@innodb_adaptive_hash_index            AS ahi,
       @@innodb_log_buffer_size / 1024 / 1024  AS log_buffer_mb\G
```

```text
  buffer_pool_mb: 256.0000
    bp_instances: 1
       page_size: 16384
change_buffering: none
             ahi: 0
   log_buffer_mb: 64.0000
```

**The buffer pool** is the cache every read and write goes through. InnoDB
never reads a row from disk directly: it reads the 16 KiB page that holds it
into the pool, and changes are made to the page in memory first. Modified
("dirty") pages are written back later by page-cleaner threads. Pages are
evicted with a midpoint-insertion LRU, so one large scan does not flush out
the working set
([Buffer Pool](https://dev.mysql.com/doc/refman/8.4/en/innodb-buffer-pool.html)).
On a dedicated database host it is by far the largest consumer of memory;
the manual suggests up to 80% of physical memory
([InnoDB Startup Options and System Variables](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html)),
less if anything else runs there. The lab's is deliberately small.

```sql test
SELECT POOL_SIZE, FREE_BUFFERS, DATABASE_PAGES, MODIFIED_DATABASE_PAGES
FROM information_schema.INNODB_BUFFER_POOL_STATS;
```

```text
+-----------+--------------+----------------+-------------------------+
| POOL_SIZE | FREE_BUFFERS | DATABASE_PAGES | MODIFIED_DATABASE_PAGES |
+-----------+--------------+----------------+-------------------------+
|     16383 |         2006 |          14377 |                     314 |
+-----------+--------------+----------------+-------------------------+
```

16 383 pages × 16 KiB is the 256 MiB pool. Your counts will differ.

**The change buffer** defers changes to secondary-index pages that are not
in the pool, and merges them when the page is next read. That saves random
reads on I/O-bound workloads, at a price: the manual warns that merging can
take hours after a bulk change and continue after a restart. In MySQL 8.4
the default `innodb_change_buffering` is `none`, so it is off
([Change Buffer](https://dev.mysql.com/doc/refman/8.4/en/innodb-change-buffer.html)).
If an older tuning guide discusses it, check which version it was written
for.

**The adaptive hash index** builds an in-memory hash over B-tree pages that
are searched the same way repeatedly. It is off by default in 8.4
(`innodb_adaptive_hash_index`,
[InnoDB Startup Options and System Variables](https://dev.mysql.com/doc/refman/8.4/en/innodb-parameters.html)).
The manual notes that access to it "can sometimes become a source of
contention under heavy workloads" and that many workloads do not benefit
([Adaptive Hash Index](https://dev.mysql.com/doc/refman/8.4/en/innodb-adaptive-hash.html)).

**The log buffer** holds redo records until they are written to the redo
log files. With `innodb_flush_log_at_trx_commit = 1`, as in this lab, the
buffer is written and flushed to disk at every commit
([Log Buffer](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log-buffer.html)).

## InnoDB on disk: a tour of the data directory

```bash test
./lab exec primary ls -l /var/lib/mysql
```

```text
-rw-r----- 1 mysql mysql  4194304 Oct 13 10:28 #ib_16384_0.dblwr
-rw-r----- 1 mysql mysql 12582912 Oct 13 10:27 #ib_16384_1.dblwr
drwxr-x--- 1 mysql mysql      768 Oct 13 10:28 #innodb_redo
drwxr-x--- 1 mysql mysql      202 Oct 13 10:28 #innodb_temp
-rw-r----- 1 mysql mysql       56 Oct 13 10:27 auto.cnf
-rw-r----- 1 mysql mysql      181 Oct 13 10:28 binlog.000001
-rw-r----- 1 mysql mysql  2983173 Oct 13 10:28 binlog.000002
-rw-r----- 1 mysql mysql 60190747 Oct 13 10:28 binlog.000003
-rw-r----- 1 mysql mysql       48 Oct 13 10:28 binlog.index
-rw------- 1 mysql mysql     1705 Oct 13 10:27 ca-key.pem
...
-rw-r----- 1 mysql mysql     5823 Oct 13 10:28 ib_buffer_pool
-rw-r----- 1 mysql mysql 12582912 Oct 13 10:28 ibdata1
-rw-r----- 1 mysql mysql 12582912 Oct 13 10:28 ibtmp1
drwxr-x--- 1 mysql mysql      178 Oct 13 10:27 mysql
-rw-r----- 1 mysql mysql 32505856 Oct 13 10:28 mysql.ibd
drwxr-x--- 1 mysql mysql     5154 Oct 13 10:27 performance_schema
...
drwxr-x--- 1 mysql mysql      150 Oct 13 10:28 shop
-rw-r----- 1 mysql mysql     1663 Oct 13 10:28 slow.log
drwxr-x--- 1 mysql mysql       28 Oct 13 10:28 sys
-rw-r----- 1 mysql mysql 33554432 Oct 13 10:28 undo_001
-rw-r----- 1 mysql mysql 33554432 Oct 13 10:28 undo_002
```

| File | What it is |
|---|---|
| `ibdata1` | The system tablespace ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-system-tablespace.html)). Never shrinks. |
| `shop/*.ibd` | File-per-table tablespaces, one per table ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-file-per-table-tablespaces.html)) |
| `mysql.ibd` | The data dictionary and the `mysql` system schema |
| `undo_001`, `undo_002` | Undo tablespaces: old row versions for rollback and MVCC ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-undo-tablespaces.html)) |
| `#innodb_redo/` | The redo log ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html)) |
| `#ib_16384_*.dblwr` | Doublewrite buffer files ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-doublewrite-buffer.html)) |
| `ibtmp1`, `#innodb_temp/` | Temporary tablespaces, recreated at startup ([manual](https://dev.mysql.com/doc/refman/8.4/en/innodb-temporary-tablespace.html)) |
| `binlog.*` | The binary log — the server's, not InnoDB's |
| `ib_buffer_pool` | List of cached pages, dumped at shutdown to warm the pool at startup |
| `auto.cnf` | This server's `server_uuid`, the source id in its GTIDs |
| `*.pem` | TLS and RSA keys generated at initialisation (Module 2) |

With `innodb_file_per_table = ON` (the default), every table gets its own
`.ibd` file. Space freed by dropping or truncating such a table goes back to
the operating system. Space freed inside `ibdata1` can only be reused by
InnoDB; the file itself never gets smaller. Decreasing the system tablespace
is not supported — the manual's only route is to restore the data into a new
instance
([System Tablespace](https://dev.mysql.com/doc/refman/8.4/en/innodb-system-tablespace.html)).
A large table that ended up in `ibdata1` is disk you never get back without
a rebuild.

The same picture is available from SQL, which is how you check a server you
cannot log in to as an OS user:

```sql test
SELECT NAME, SPACE_TYPE, FILE_SIZE / 1024 / 1024 AS size_mb
FROM information_schema.INNODB_TABLESPACES
WHERE NAME LIKE 'shop/%' OR SPACE_TYPE IN ('Undo', 'System')
ORDER BY SPACE_TYPE, NAME;

SELECT FILE_NAME, TABLESPACE_NAME, FILE_TYPE
FROM information_schema.FILES
WHERE TABLESPACE_NAME IN ('innodb_system', 'mysql')
   OR FILE_TYPE = 'UNDO LOG';
```

```text
+------------------+------------+---------+
| NAME             | SPACE_TYPE | size_mb |
+------------------+------------+---------+
| shop/customers   | Single     | 11.0000 |
| shop/inventory   | Single     |  0.2344 |
| shop/order_items | Single     | 76.0000 |
| shop/orders      | Single     | 23.0000 |
| shop/payments    | Single     | 22.0000 |
| shop/products    | Single     |  0.2656 |
| innodb_temporary | System     | 12.0000 |
| innodb_undo_001  | Undo       | 32.0000 |
| innodb_undo_002  | Undo       | 32.0000 |
+------------------+------------+---------+
+-------------+-----------------+------------+
| FILE_NAME   | TABLESPACE_NAME | FILE_TYPE  |
+-------------+-----------------+------------+
| ./undo_001  | innodb_undo_001 | UNDO LOG   |
| ./undo_002  | innodb_undo_002 | UNDO LOG   |
| ./ibdata1   | innodb_system   | TABLESPACE |
| ./mysql.ibd | mysql           | TABLESPACE |
+-------------+-----------------+------------+
```

The system tablespace itself is space id 0 and does not appear in
`INNODB_TABLESPACES`; `information_schema.FILES` has it.

**The doublewrite buffer** protects against torn pages. A 16 KiB InnoDB
page is larger than the unit many file systems and devices write atomically
(often 4 KiB), so a
crash mid-write can leave half an old page and half a new one. The redo log
cannot repair that: redo records describe changes to a page, and need an
intact page to apply them to. So InnoDB first writes pages to the
doublewrite files and only then to their real place. If a write is
interrupted, crash recovery finds a good copy of the page in the doublewrite
buffer.
The two files above are the flush-list and LRU doublewrite files for the
lab's single buffer pool instance.

## Two logs: redo and binary

MySQL writes every committed change twice.

| | Redo log | Binary log |
|---|---|---|
| Owner | InnoDB | The server (SQL layer) |
| Contents | Physical changes to pages | Logical changes: row images or statements |
| Size | Fixed capacity, reused in a circle | Grows; files rotate and expire |
| Used for | Crash recovery of this server | Replication, point-in-time recovery |

The **redo log** lives in `#innodb_redo/`, sized by
`innodb_redo_log_capacity` (256 MiB in this lab); InnoDB keeps 32 files of
1/32 of the capacity each and recycles them
([Redo Log](https://dev.mysql.com/doc/refman/8.4/en/innodb-redo-log.html)).
Every change InnoDB makes, including changes that are later rolled back, is
redo-logged, and the redo reaches disk before the changed page does
(write-ahead logging). A **checkpoint** marks how far dirty
pages have been written to the tablespaces; redo older than the checkpoint
is no longer needed and its space is reused.

The **binary log** records committed transactions only, in commit order, in
a format another server can replay
([The Binary Log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)).
Replicas apply it; point-in-time recovery replays it on top of a backup.

`performance_schema.log_status` shows both positions in one consistent
snapshot. Watch what a rolled-back transaction and a committed one cost in
each log:

```sql test
SELECT STORAGE_ENGINES->>'$.InnoDB.LSN', LOCAL->>'$.binary_log_position'
  INTO @lsn, @pos FROM performance_schema.log_status;

START TRANSACTION;
UPDATE shop.inventory SET reserved = reserved + 1;
ROLLBACK;

SELECT STORAGE_ENGINES->>'$.InnoDB.LSN' - @lsn AS redo_bytes,
       LOCAL->>'$.binary_log_position' - @pos AS binlog_bytes
FROM performance_schema.log_status;

CREATE DATABASE lab;
CREATE TABLE lab.t (id INT PRIMARY KEY, v INT);

SELECT STORAGE_ENGINES->>'$.InnoDB.LSN', LOCAL->>'$.binary_log_position'
  INTO @lsn, @pos FROM performance_schema.log_status;

INSERT INTO lab.t VALUES (1, 1);

SELECT STORAGE_ENGINES->>'$.InnoDB.LSN' - @lsn AS redo_bytes,
       LOCAL->>'$.binary_log_position' - @pos AS binlog_bytes
FROM performance_schema.log_status;
```

```text
+------------+--------------+
| redo_bytes | binlog_bytes |
+------------+--------------+
|     479959 |            0 |
+------------+--------------+
+------------+--------------+
| redo_bytes | binlog_bytes |
+------------+--------------+
|        546 |          272 |
+------------+--------------+
```

Updating 3 000 rows and rolling back cost almost 470 KiB of redo and nothing
in the binary log. The one-row insert appears in both. Here is that insert
in the binary log:

```bash test
f=$(./lab sql -N -e "SELECT LOCAL->>'$.binary_log_file' FROM performance_schema.log_status")
./lab sql --table -e "SHOW BINLOG EVENTS IN '$f'" | tail -6
./lab sql -e "DROP DATABASE lab"
```

```text
| binlog.000018 | 1074 | Gtid       | 1 | 1153 | SET @@SESSION.GTID_NEXT= 'c2d38c5f-...:164' |
| binlog.000018 | 1153 | Query      | 1 | 1224 | BEGIN                                       |
| binlog.000018 | 1224 | Table_map  | 1 | 1271 | table_id: 99 (lab.t)                        |
| binlog.000018 | 1271 | Write_rows | 1 | 1315 | table_id: 99 flags: STMT_END_F              |
| binlog.000018 | 1315 | Xid        | 1 | 1346 | COMMIT /* xid=150 */                        |
+---------------+------+------------+---+------+---------------------------------------------+
```

**Why both?** The redo log cannot serve replication: it is physical,
InnoDB-specific, contains uncommitted work and is overwritten in a circle.
The binary log cannot serve crash recovery: it knows nothing about which
pages reached disk. So each does one job, and the two must agree on which
transactions committed.

They agree through an internal **two-phase commit**. At `COMMIT`, InnoDB
first *prepares* the transaction (its redo is durable), then the server
writes the transaction to the binary log and syncs it, then InnoDB commits.
The `Xid` event above carries the id that links the two. If the server dies
between the steps, recovery commits every prepared transaction that reached
the binary log and rolls back the rest
([The Binary Log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)).
That guarantee holds only if both logs are actually flushed at commit:
`innodb_flush_log_at_trx_commit = 1` and `sync_binlog = 1`, which the manual
recommends for "the greatest possible durability and consistency"
([Binary Logging Options and Variables](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html)).
Module 2's exercise is about what happens when someone relaxes them.

<!-- founder-review: a real story about relaxed durability settings
(innodb_flush_log_at_trx_commit=2 or sync_binlog=0) and what was lost after
a host crash would help here -->

## Crash recovery, observed

When `mysqld` starts after an unclean stop, recovery runs in this order
([InnoDB Recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)):

1. **Redo apply.** InnoDB finds the last checkpoint and replays redo from
   there, so every page reflects every logged change. Torn pages are first
   repaired from the doublewrite buffer.
2. **Binary log / XA recovery.** The server reads the last binary log and
   decides, for each prepared transaction, commit or roll back.
3. **Rollback of incomplete transactions** from the undo logs, in the
   background, after the server already accepts connections.

You can watch it. The next block opens a transaction that inserts 50 000
rows and leaves it uncommitted, then kills `mysqld` with `SIGKILL` — the
equivalent of pulling the power cable. Never do this to a production server.

```bash test
./lab sql -e "CREATE DATABASE lab;
  CREATE TABLE lab.crash_demo (id INT PRIMARY KEY, note VARCHAR(20));
  INSERT INTO lab.crash_demo VALUES (1, 'committed')"

# A client inside the container: insert 50 000 rows, do not commit, wait.
docker compose exec -d -T -e MYSQL_PWD="${DBRE_ROOT_PASSWORD:-dbre-lab-root}" \
  primary mysql -uroot -e "
    BEGIN;
    INSERT INTO lab.crash_demo
      SELECT id + 1, 'uncommitted' FROM shop.orders WHERE id <= 50000;
    SELECT SLEEP(600);"
for _ in $(seq 1 60); do   # wait until all 50 000 rows are inserted
  [ "$(./lab sql -N -e "SELECT IFNULL(MAX(trx_rows_modified), 0)
                        FROM information_schema.INNODB_TRX")" = 50000 ] && break
  sleep 1
done
./lab sql --table -e "SELECT trx_state, trx_rows_modified
                      FROM information_schema.INNODB_TRX"

since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker compose kill -s KILL primary
./lab up >/dev/null
docker compose logs --no-log-prefix --since "$since" primary \
  | grep -E 'crash recovery|to undo|Rolling back|Rollback of trx'
```

```text
+-----------+-------------------+
| trx_state | trx_rows_modified |
+-----------+-------------------+
| RUNNING   |             50000 |
+-----------+-------------------+
... [Note] [MY-012552] [InnoDB] Starting crash recovery.
... [Note] [MY-013023] [InnoDB] 1 transaction(s) which must be rolled back or
    cleaned up in total 50000 row operations to undo
... [System] [MY-010229] [Server] Starting XA crash recovery...
... [System] [MY-010232] [Server] XA crash recovery finished.
... [Note] [MY-013011] [InnoDB] Rolling back trx with id 3343, 50000 rows to undo
... [Note] [MY-013012] [InnoDB] Rollback of trx with id 3343 completed
```

The committed row survived; the 50 000 uncommitted rows were undone:

```sql test
SELECT note, COUNT(*) FROM lab.crash_demo GROUP BY note;
DROP DATABASE lab;
```

```text
+-----------+----------+
| note      | COUNT(*) |
+-----------+----------+
| committed |        1 |
+-----------+----------+
```

Rolling back can take three or four times as long as the transaction had
been running, and it cannot be cancelled
([InnoDB Recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)).
A batch job that has been open for an hour when the server dies can cost
hours of rollback after restart: another reason to keep transactions short.

## information_schema, performance_schema and sys

Three schemas answer questions about the server. They are not
interchangeable.

| Schema | Answers | Backed by |
|---|---|---|
| `information_schema` | What exists: tables, columns, privileges, tablespaces | The data dictionary and engine views |
| `performance_schema` | What is happening and what it cost: threads, statements, waits, locks, variables | In-memory instrumentation, reset at restart |
| `sys` | The same, readable: views and procedures over the other two | Views (no data of its own) |

([INFORMATION_SCHEMA Tables](https://dev.mysql.com/doc/refman/8.4/en/information-schema.html),
[MySQL Performance Schema](https://dev.mysql.com/doc/refman/8.4/en/performance-schema.html),
[MySQL sys Schema](https://dev.mysql.com/doc/refman/8.4/en/sys-schema.html))

```sql test
SELECT TABLE_NAME, TABLE_ROWS,
       ROUND(DATA_LENGTH / 1024 / 1024, 1)  AS data_mb,
       ROUND(INDEX_LENGTH / 1024 / 1024, 1) AS index_mb
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'shop'
ORDER BY DATA_LENGTH DESC;

SELECT COUNT(*) FROM shop.orders;

SELECT table_name, rows_fetched, io_read
FROM sys.schema_table_statistics
WHERE table_schema = 'shop'
ORDER BY rows_fetched DESC
LIMIT 3;
```

```text
+-------------+------------+---------+----------+
| TABLE_NAME  | TABLE_ROWS | data_mb | index_mb |
+-------------+------------+---------+----------+
| order_items |     489721 |    46.6 |     18.5 |
| orders      |     199800 |     9.5 |      5.5 |
| payments    |     193806 |     9.5 |      4.5 |
...
| COUNT(*) |
|   200000 |
...
| table_name | rows_fetched | io_read    |
+------------+--------------+------------+
| orders     |       600180 | 13.91 MiB  |
...
```

Note `TABLE_ROWS` = 199 800 against a real count of 200 000. For InnoDB,
row counts and sizes in `information_schema.TABLES` are estimates from
sampled index statistics, not counts. They are good enough for "which table
is biggest", not for reconciliation. The `sys` numbers are cumulative since
the server started (and you just restarted it), so yours will differ.

## Common mistakes and troubleshooting

- **Treating `TABLE_ROWS` as a row count.** It is an estimate for InnoDB.
  Use `COUNT(*)` when the number matters.
- **Tuning the change buffer or adaptive hash index from an old guide.**
  Both are off by default in 8.4. Turn them on only with a measurement that
  shows a benefit on your workload.
- **Assuming `DROP TABLE` frees disk.** Only for file-per-table tablespaces.
  Check `INNODB_TABLES.SPACE`: space 0 is `ibdata1`.
- **Deleting "old" redo or binary log files by hand.** `#innodb_redo` files
  are managed by InnoDB; binary logs are removed with `PURGE BINARY LOGS`
  or by `binlog_expire_logs_seconds`, never with `rm`, or `binlog.index` and
  the replicas disagree with the disk.
- **Reading `performance_schema` right after a restart** and concluding a
  query never ran. Its tables are in memory and start empty.
- **Running `SELECT * FROM information_schema.INNODB_BUFFER_PAGE` on a large
  production pool.** It walks the whole pool and is expensive
  ([manual](https://dev.mysql.com/doc/refman/8.4/en/information-schema-innodb-buffer-page-table.html)).
  Fine in the lab. `sys.innodb_buffer_stats_by_table` reads the same table
  and has the same cost; on a large pool, run either off-peak or not at all.

## Further reading

- [InnoDB Architecture](https://dev.mysql.com/doc/refman/8.4/en/innodb-architecture.html)
- [InnoDB On-Disk Structures](https://dev.mysql.com/doc/refman/8.4/en/innodb-on-disk-structures.html)
- [Connection Management](https://dev.mysql.com/doc/refman/8.4/en/connection-management.html)
- [The performance_schema threads table](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-threads-table.html)
- [InnoDB Recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)
- [The Binary Log](https://dev.mysql.com/doc/refman/8.4/en/binary-log.html)

## Next

Do the [exercise](exercise.md): trace a connection to its OS thread, a write
to its binary log file and a table to its pages, and move a table out of
`ibdata1`. Then check yourself with the [quiz](quiz.md).

Module 2, [Installation, configuration and secure access](../02-install-config-access/README.md),
looks at how this data directory was created and who is allowed in.
