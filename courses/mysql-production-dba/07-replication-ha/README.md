# Module 7 — Replication and high availability fundamentals

`time: ~90 min` · `lab: ./lab scenario setup 07-replication-lag`, `./lab scenario setup 07-broken-replication` · `level: fundamentals`

Almost every production MySQL server has a replica: for reads, for
backups, for failover. Replication is simple to set up and easy to break
quietly. A replica can fall hours behind while its threads report "Yes",
carry transactions the primary never ran, or be "fixed" by skipping an
error in a way that makes its data permanently wrong. This module follows a
change from the primary's commit to the replica's, shows where it can stall
or fail, and covers the fixes that keep the replica correct, not just
running. It ends with what high availability adds on top: switchover,
failover, and the fencing that keeps two primaries from accepting writes at
once.

## Learning objectives

By the end of this module you can:

- name each thread a change passes through, from the primary's binary log
  to the replica's tables, and find it in `performance_schema`;
- explain GTIDs and auto-positioning, and compare GTID sets with
  `GTID_SUBSET()` and `GTID_SUBTRACT()`;
- read `SHOW REPLICA STATUS` and the `performance_schema` replication
  tables, and know which fields lie;
- explain the multi-threaded applier, `replica_preserve_commit_order`,
  `read_only` and `super_read_only`;
- say what semi-synchronous replication guarantees and what it does not,
  and watch it fall back to asynchronous;
- diagnose replication lag: tell receiver lag from applier lag, measure it
  with GTIDs and a heartbeat, and find the cause;
- find errant transactions, explain why they break failover, and repair
  errors 1062 and 1032 without losing consistency;
- outline a switchover and a failover runbook, and explain split brain and
  fencing.

## Prerequisites

- The lab is running: `./lab up`. Commands run from the `labs/` directory.
- Module 1 (the binary log) and Module 6 (GTIDs in backups and
  `mysqlbinlog`).

The lab has one primary (`server_id=1`) and one replica (`server_id=2`),
with GTIDs, row-based logging and auto-positioning
(`labs/mysql/primary.cnf`, `labs/mysql/replica.cnf`). `./lab sql replica`
opens a shell on the replica.

## How a change reaches the replica

A committed transaction on the primary travels through five stages
([Replication Threads](https://dev.mysql.com/doc/refman/8.4/en/replication-threads.html)):

1. The primary writes the transaction to its **binary log** at commit.
2. A **binlog dump thread** on the primary, one per connected replica,
   reads the binary log and sends events to the replica.
3. The replica's **receiver thread** (the "I/O thread") writes them to the
   replica's **relay log**.
4. The **coordinator** (the "SQL thread") reads the relay log and hands
   transactions to **worker threads**.
5. The workers apply the changes and commit, writing them to the replica's
   own binary log as well (`log_replica_updates=ON`).

Each stage can stall on its own, which is why "is replication running?"
always has two answers. Find each stage's thread:

```sql test
SELECT PROCESSLIST_ID, PROCESSLIST_USER, PROCESSLIST_COMMAND, PROCESSLIST_STATE
  FROM performance_schema.threads
 WHERE PROCESSLIST_COMMAND LIKE 'Binlog Dump%';
```

```text
+----------------+------------------+---------------------+-----------------------------------------------------------------+
| PROCESSLIST_ID | PROCESSLIST_USER | PROCESSLIST_COMMAND | PROCESSLIST_STATE                                               |
+----------------+------------------+---------------------+-----------------------------------------------------------------+
|              9 | repl             | Binlog Dump GTID    | Source has sent all binlog to replica; waiting for more updates |
+----------------+------------------+---------------------+-----------------------------------------------------------------+
```

```sql test replica
SELECT NAME, PROCESSLIST_STATE
  FROM performance_schema.threads
 WHERE NAME LIKE 'thread/sql/replica_%'
 ORDER BY NAME;
```

```text
+---------------------------+----------------------------------------------------------+
| NAME                      | PROCESSLIST_STATE                                        |
+---------------------------+----------------------------------------------------------+
| thread/sql/replica_io     | Waiting for source to send event                         |
| thread/sql/replica_sql    | Replica has read all relay log; waiting for more updates |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
| thread/sql/replica_worker | Waiting for an event from Coordinator                    |
+---------------------------+----------------------------------------------------------+
```

`Binlog Dump GTID` means the replica asked for events by GTID set
(auto-positioning), not by file and position.

## Binary log format: ROW

With `binlog_format=ROW` (the default, and deprecated as a setting: the
other formats are on their way out) the binary log carries the before and
after image of every changed row, not the SQL text
([Replication Formats](https://dev.mysql.com/doc/refman/8.4/en/replication-formats.html),
[binlog_format](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html#sysvar_binlog_format)).
Row-based replication applies exactly what changed on the primary, so
non-deterministic statements (`UUID()`, `LIMIT` without `ORDER BY`) cannot
diverge. The costs: a statement that changes a million rows produces a
million row images, and a table without a primary key forces the replica
to search for each row with a table scan, once per changed row
([sql_require_primary_key](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_sql_require_primary_key)).

```sql test
SELECT @@binlog_format, @@binlog_row_image, @@gtid_mode, @@enforce_gtid_consistency;
```

```text
+-----------------+--------------------+-------------+----------------------------+
| @@binlog_format | @@binlog_row_image | @@gtid_mode | @@enforce_gtid_consistency |
+-----------------+--------------------+-------------+----------------------------+
| ROW             | FULL               | ON          | ON                         |
+-----------------+--------------------+-------------+----------------------------+
```

## GTIDs and auto-positioning

Every transaction committed with `gtid_mode=ON` gets a global transaction
identifier, `source_uuid:sequence`, where `source_uuid` is the
`server_uuid` of the server that first committed it. The GTID travels with
the transaction to every replica. `gtid_executed` is the set of every GTID
a server has committed, written as ranges
([GTID Format and Storage](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-concepts.html)).

With `SOURCE_AUTO_POSITION=1` the replica sends its `gtid_executed` (plus
what it has already received) when it connects, and the primary sends
everything that is not in it. No file names, no positions: a replica can be
pointed at any server that has the transactions it lacks, which is what
makes failover tractable
([GTID Auto-Positioning](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-auto-positioning.html)).
A server also refuses to run a transaction whose GTID it has already
executed, without an error (Module 6 met this "auto-skip" during
point-in-time recovery).

```sql test replica
SELECT CHANNEL_NAME, HOST, PORT, USER, AUTO_POSITION, SSL_ALLOWED
  FROM performance_schema.replication_connection_configuration;
SELECT @@server_uuid, @@GLOBAL.gtid_executed;
```

```text
+--------------+---------+------+------+---------------+-------------+
| CHANNEL_NAME | HOST    | PORT | USER | AUTO_POSITION | SSL_ALLOWED |
+--------------+---------+------+------+---------------+-------------+
|              | primary | 3306 | repl | 1             | YES         |
+--------------+---------+------+------+---------------+-------------+
+--------------------------------------+---------------------------------------------+
| @@server_uuid                        | @@GLOBAL.gtid_executed                      |
+--------------------------------------+---------------------------------------------+
| 2f1e6250-c6fa-11f1-ad34-668f2555875d | 2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1-1211 |
+--------------------------------------+---------------------------------------------+
```

The replica's `gtid_executed` holds only the primary's UUID. A healthy
replica's set is a subset of its primary's; anything under its own UUID is
something it ran by itself.

Two functions answer most GTID questions
([Functions Used with GTIDs](https://dev.mysql.com/doc/refman/8.4/en/gtid-functions.html)):

- `GTID_SUBSET(a, b)`: is every transaction in `a` also in `b`? "Has the
  replica executed everything the primary has?" is
  `GTID_SUBSET(primary_set, replica_set)`.
- `GTID_SUBTRACT(a, b)`: what is in `a` but not in `b`? On the replica,
  `GTID_SUBTRACT(replica_set, primary_set)` lists **errant transactions**;
  more on those below.

Ask both questions of the lab. The primary's set comes from one server and
the comparison runs on the other, so the script carries it across:

```bash test
primary_set="$(./lab sql primary -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
./lab sql replica --table -e "
  SELECT GTID_SUBSET('$primary_set', @@GLOBAL.gtid_executed) AS replica_has_everything,
         GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_set') AS replica_only"
```

```text
+------------------------+--------------+
| replica_has_everything | replica_only |
+------------------------+--------------+
|                      1 |              |
+------------------------+--------------+
```

`replica_only` is empty: the replica has executed nothing of its own. That
is the healthy state, and on this lab it is not an accident. The MySQL
container image loads its time zone tables when it initialises a data
directory, with binary logging on, before anything else happens. Every
fresh server therefore starts with five transactions under its own UUID:
four `TRUNCATE TABLE` statements and one transaction that inserts the time
zone rows. On the primary they are `<primary uuid>:1-5`, the first
transactions in its binary log, and they replicate like any other:

```text
SET @@SESSION.GTID_NEXT= '2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1'/*!*/;
TRUNCATE TABLE time_zone
...
SET @@SESSION.GTID_NEXT= '2f1ddfc8-c6fa-11f1-b057-da1ec2050429:4'/*!*/;
TRUNCATE TABLE time_zone_transition_type
SET @@SESSION.GTID_NEXT= '2f1ddfc8-c6fa-11f1-b057-da1ec2050429:5'/*!*/;
... (row events: INSERT INTO `mysql`.`time_zone_transition` ...)
```

On the replica the same loads became `<replica uuid>:1-5`: transactions
the primary never ran. That is how errant transactions are born, with no
one misbehaving: a server initialised, or touched, before it became a
replica. The data is identical, so they do no harm while it stays a
replica; promote it, and every other server has to fetch them from it.

`./lab up` therefore runs
[`RESET BINARY LOGS AND GTIDS`](https://dev.mysql.com/doc/refman/8.4/en/reset-binary-logs-and-gtids.html)
on the replica before it first configures replication. The statement
deletes every binary log file and empties `gtid_executed` and
`gtid_purged`; the rows on disk stay as they are. On a freshly initialised
replica that is the correct move: its only history is the image's own
setup, the time zone data is identical to the primary's (which then
replicates its own loads on top), and the replica fetches everything else
from the primary by auto-positioning. On a replica that holds real data it
is the wrong move on its own: the server forgets which transactions it
has applied, so auto-positioning sends them all again, and the binary logs
that a point-in-time recovery or another replica needs are gone. Rebuild
that kind of replica from a backup, or repair one errant transaction at a
time ("Errant transactions" below).

## Reading replica status

`SHOW REPLICA STATUS` is the classic view; the important fields
([SHOW REPLICA STATUS](https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html)):

```sql
SHOW REPLICA STATUS\G
```

```text
                  Source_Host: primary
              Source_Log_File: binlog.000004
          Read_Source_Log_Pos: 120677467
               Relay_Log_File: relay.000005
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
          Exec_Source_Log_Pos: 120677467
        Seconds_Behind_Source: 0
                Last_IO_Errno: 0
               Last_SQL_Errno: 0
    Replica_SQL_Running_State: Replica has read all relay log; waiting for more updates
           Retrieved_Gtid_Set: 2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1-1211
            Executed_Gtid_Set: 2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1-1211
                Auto_Position: 1
```

- `Replica_IO_Running` / `Replica_SQL_Running`: receiver and applier.
  `Connecting` for the receiver means it cannot reach or log in to the
  source; look at `Last_IO_Error`.
- `Retrieved_Gtid_Set` vs `Executed_Gtid_Set`: received vs applied. If
  retrieved grows and executed does not, the applier is the bottleneck.
- `Seconds_Behind_Source`: see "Measuring lag" for why not to trust it
  alone.
- `Last_SQL_Error`: with a multi-threaded applier, the coordinator's
  summary; the full error per worker is in `performance_schema`.

The `performance_schema` replication tables hold the same information in
queryable form, per thread and with timestamps
([Performance Schema Replication Tables](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-tables.html)).
This is the query to keep for monitoring scripts:

```sql test replica
SELECT c.SERVICE_STATE AS receiver, a.SERVICE_STATE AS applier,
       c.LAST_ERROR_NUMBER AS receiver_errno,
       (SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker w
         WHERE w.LAST_ERROR_NUMBER <> 0) AS workers_in_error,
       c.LAST_HEARTBEAT_TIMESTAMP
  FROM performance_schema.replication_connection_status c
  JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME);
```

```text
+----------+---------+----------------+------------------+----------------------------+
| receiver | applier | receiver_errno | workers_in_error | LAST_HEARTBEAT_TIMESTAMP   |
+----------+---------+----------------+------------------+----------------------------+
| ON       | ON      |              0 |                0 | 0000-00-00 00:00:00.000000 |
+----------+---------+----------------+------------------+----------------------------+
```

`LAST_HEARTBEAT_TIMESTAMP` is the replication protocol's own heartbeat.
The source sends one only after `SOURCE_HEARTBEAT_PERIOD` seconds without
events to send (by default half of `replica_net_timeout`, so 30 seconds),
which is why a replica that has just been busy shows zeros
([CHANGE REPLICATION SOURCE TO](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html)).
It shows that the connection is alive, not that the replica is current.

## The multi-threaded applier

A primary commits many transactions in parallel; a single applier thread
would replay them one at a time and fall behind under load. In 8.4 the
replica applies in parallel by default: `replica_parallel_workers=4`,
`replica_parallel_type=LOGICAL_CLOCK`, and the primary always uses
writesets to mark which transactions are independent (they touched
different rows), so the replica may run them at the same time
([replica_parallel_workers](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#sysvar_replica_parallel_workers),
[What Is New in MySQL 8.4](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)).

`replica_preserve_commit_order=ON` (the default) makes workers commit in
the primary's order, even when they execute in parallel. Without it, a
reader on the replica can see transaction 102 committed while 101 is not
yet, a state that never existed on the primary. With it, one slow
transaction holds back the commit of everything after it: you will see
workers in the state `Waiting for preceding transaction to commit` or
`Waiting for dependent transaction to commit`.

```sql test replica
SELECT @@replica_parallel_workers, @@replica_parallel_type,
       @@replica_preserve_commit_order;
SELECT WORKER_ID, SERVICE_STATE, LAST_APPLIED_TRANSACTION, LAST_ERROR_NUMBER
  FROM performance_schema.replication_applier_status_by_worker;
```

```text
+----------------------------+-------------------------+---------------------------------+
| @@replica_parallel_workers | @@replica_parallel_type | @@replica_preserve_commit_order |
+----------------------------+-------------------------+---------------------------------+
|                          4 | LOGICAL_CLOCK           |                               1 |
+----------------------------+-------------------------+---------------------------------+
+-----------+---------------+------------------------------------------+-------------------+
| WORKER_ID | SERVICE_STATE | LAST_APPLIED_TRANSACTION                 | LAST_ERROR_NUMBER |
+-----------+---------------+------------------------------------------+-------------------+
|         1 | ON            | f5295318-c6f6-11f1-90ea-9a823957eb04:134 |                 0 |
|         2 | ON            | f5295318-c6f6-11f1-90ea-9a823957eb04:113 |                 0 |
|         3 | ON            | f5295318-c6f6-11f1-90ea-9a823957eb04:38  |                 0 |
|         4 | ON            |                                          |                 0 |
+-----------+---------------+------------------------------------------+-------------------+
```

## read_only and super_read_only

A replica must not take writes from anyone but its applier. `read_only=ON`
blocks clients without `CONNECTION_ADMIN` (or `SUPER`); administrators can
still write. `super_read_only=ON` blocks them too. The replication applier
is exempt from both
([super_read_only](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_super_read_only)).
The lab sets both on the replica with `SET PERSIST`, so they survive a
restart. Even root is refused:

```sql test replica expect-error
INSERT INTO shop.customers (email, full_name, country_code, created_at)
VALUES ('blocked@example.test', 'Blocked Write', 'EE', '2026-01-01 00:00:00');
```

```text
ERROR 1290 (HY000) at line 1: The MySQL server is running with the --super-read-only
option so it cannot execute this statement
```

Run every replica with both on. Without `super_read_only`, an
administrator's "quick fix" on the replica creates exactly the errant
transactions the exercise makes you clean up.

## Semi-synchronous replication

Replication is asynchronous by default: the primary commits and answers
the client without waiting for any replica. If the primary dies, committed
transactions may exist nowhere else. With semi-synchronous replication the
primary waits, at commit, until at least
`rpl_semi_sync_source_wait_for_replica_count` replicas acknowledge that
they have **received and written the transaction to their relay log**
([Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync.html)).
It guarantees that a transaction the client saw committed exists on at
least two servers. It does **not** guarantee that the replica has applied
it (a semi-sync replica can still lag), and it gives up after
`rpl_semi_sync_source_timeout` milliseconds without an acknowledgement and
continues asynchronously.

In 8.4 the plugins are `rpl_semi_sync_source` (`semisync_source.so`) and
`rpl_semi_sync_replica` (`semisync_replica.so`)
([Installing Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync-installation.html)).
Install and enable them; `INSTALL PLUGIN` writes to the `mysql` schema, so
the replica needs `super_read_only` off for a moment, and the receiver must
reconnect to register as semi-synchronous:

```bash test
./lab sql primary -e "
  INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';
  SET GLOBAL rpl_semi_sync_source_enabled = ON;
  SET GLOBAL rpl_semi_sync_source_timeout = 2000;"
./lab sql replica -e "
  SET GLOBAL super_read_only = OFF;
  INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';
  SET GLOBAL super_read_only = ON;
  SET GLOBAL rpl_semi_sync_replica_enabled = ON;
  STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;"
sleep 1
./lab sql primary --table -e "
  SHOW GLOBAL STATUS WHERE Variable_name IN
    ('Rpl_semi_sync_source_status', 'Rpl_semi_sync_source_clients');
  SHOW GLOBAL VARIABLES LIKE 'rpl_semi_sync_source_wait%';"
```

```text
+------------------------------+-------+
| Variable_name                | Value |
+------------------------------+-------+
| Rpl_semi_sync_source_clients | 1     |
| Rpl_semi_sync_source_status  | ON    |
+------------------------------+-------+
+---------------------------------------------+------------+
| Variable_name                               | Value      |
+---------------------------------------------+------------+
| rpl_semi_sync_source_wait_for_replica_count | 1          |
| rpl_semi_sync_source_wait_no_replica        | ON         |
| rpl_semi_sync_source_wait_point             | AFTER_SYNC |
+---------------------------------------------+------------+
```

`AFTER_SYNC` (the default) waits for the acknowledgement after the
transaction is in the primary's binary log but before it is committed in
InnoDB, so no other session can see a transaction that no replica has.
Now take the replica away and time two commits:

```bash test
./lab sql primary -e "CREATE DATABASE lab; CREATE TABLE lab.t (id INT PRIMARY KEY)"
./lab sql replica -e "STOP REPLICA IO_THREAD"
for id in 1 2; do
  start=$(date +%s)
  ./lab sql primary -e "INSERT INTO lab.t VALUES ($id)"
  echo "insert $id took about $(( $(date +%s) - start ))s"
done
./lab sql primary --table -e "
  SHOW GLOBAL STATUS WHERE Variable_name IN
    ('Rpl_semi_sync_source_status', 'Rpl_semi_sync_source_no_tx');"
./lab sql replica -e "START REPLICA IO_THREAD"
```

```text
insert 1 took about 2s
insert 2 took about 0s
+-----------------------------+-------+
| Variable_name               | Value |
+-----------------------------+-------+
| Rpl_semi_sync_source_no_tx  | 2     |
| Rpl_semi_sync_source_status | OFF   |
+-----------------------------+-------+
```

The first insert waited the full two-second timeout, then the primary
switched to asynchronous replication (`status OFF`) and the second insert
did not wait at all. Both committed without any replica having them
(`no_tx` counts commits not acknowledged; your count may include the
`CREATE` statements). A production timeout is often much longer, and some
teams set it very high so that the primary stops accepting writes instead
of silently degrading; that is a business decision, not a default. Alert on
`Rpl_semi_sync_source_status`
([Semisynchronous Replication Monitoring](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync-monitoring.html)).

Put the lab back to asynchronous replication:

```bash test
./lab sql replica -e "
  STOP REPLICA IO_THREAD;
  SET GLOBAL rpl_semi_sync_replica_enabled = OFF;
  SET GLOBAL super_read_only = OFF;
  UNINSTALL PLUGIN rpl_semi_sync_replica;
  SET GLOBAL super_read_only = ON;
  START REPLICA IO_THREAD;"
./lab sql primary -e "
  SET GLOBAL rpl_semi_sync_source_enabled = OFF;
  UNINSTALL PLUGIN rpl_semi_sync_source;
  DROP DATABASE lab;"
```

## Replication lag

### Causes

Lag is the applier (or, less often, the receiver) running behind the
primary. The usual causes, roughly in the order you meet them:

- **A large transaction.** A `DELETE` of ten million rows commits on the
  primary in one go and is applied on the replica only after it is
  complete there too; with `replica_preserve_commit_order`, everything
  after it waits. Lag jumps by the transaction's run time.
- **Tables without a primary key** under row-based replication: one table
  scan per changed row on the replica.
- **DDL.** An `ALTER TABLE` that took 40 minutes on the primary takes about
  40 minutes on the replica, after it finishes on the primary, and blocks
  the transactions behind it.
- **Too little parallelism.** One worker, or a workload that writes the
  same rows (hot counters) so writesets cannot parallelise it.
- **Something on the replica blocking the applier**: a long report holding
  a metadata lock, a backup holding `FLUSH TABLES WITH READ LOCK`. The
  `07-replication-lag` exercise is this case.
- **Replica resources**: a smaller instance, slower disks, a cold buffer
  pool after a restart.
- **Receiver lag**: network bandwidth or latency between data centres. The
  applier is idle and still the replica is behind.

### Measuring lag

`Seconds_Behind_Source` is the difference between the replica's clock and
the original commit timestamp of the event the applier is processing. The
manual is frank about its limits
([SHOW REPLICA STATUS](https://dev.mysql.com/doc/refman/8.4/en/show-replica-status.html)):
it measures only how far the applier is behind the receiver, so with a slow
network it shows 0 while the receiver is far behind; it is `NULL` when the
applier is not running; clock changes skew it. During a large transaction
it reports 0 until the transaction starts applying, then jumps.

Two measurements that do not lie:

- **GTID sets**: `GTID_SUBSET(primary_set, replica_set)` is 1 when the
  replica has everything. It says whether the replica is behind, not by
  how long.
- **A heartbeat table**: a job on the primary writes the current time into
  a one-row table every second; on the replica, `NOW()` minus that value is
  the true delay, end to end, as far as the replica's data is concerned.
  This is what `pt-heartbeat` from Percona Toolkit does. The lag exercise
  runs one.

See the difference between receiving and applying. Stop only the applier,
write on the primary, and look:

```bash test
./lab sql primary -e "CREATE DATABASE lab; CREATE TABLE lab.events (id INT PRIMARY KEY)"
sleep 1
./lab sql replica -e "STOP REPLICA SQL_THREAD"
./lab sql primary -e "INSERT INTO lab.events VALUES (1), (2), (3)"
sleep 1
./lab sql replica -e "SHOW REPLICA STATUS\G" \
  | grep -E 'Replica_(IO|SQL)_Running:|Seconds_Behind_Source'
primary_set="$(./lab sql primary -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
./lab sql replica --table -e "
  SELECT GTID_SUBSET('$primary_set', @@GLOBAL.gtid_executed) AS caught_up,
         GTID_SUBTRACT('$primary_set', @@GLOBAL.gtid_executed) AS missing,
         GTID_SUBTRACT(RECEIVED_TRANSACTION_SET, @@GLOBAL.gtid_executed) AS received_not_applied
    FROM performance_schema.replication_connection_status"
./lab sql replica -e "START REPLICA SQL_THREAD"
```

```text
           Replica_IO_Running: Yes
          Replica_SQL_Running: No
        Seconds_Behind_Source: NULL
+-----------+------------------------------------------+------------------------------------------+
| caught_up | missing                                  | received_not_applied                     |
+-----------+------------------------------------------+------------------------------------------+
|         0 | f5295318-c6f6-11f1-90ea-9a823957eb04:142 | f5295318-c6f6-11f1-90ea-9a823957eb04:142 |
+-----------+------------------------------------------+------------------------------------------+
```

The receiver has transaction 142 in the relay log
(`RECEIVED_TRANSACTION_SET` in `replication_connection_status`); the
applier has not run it. `Seconds_Behind_Source` is `NULL`, which many dashboards display as 0
or as "no data". The GTID comparison names the exact missing transaction.

```sql test
DROP DATABASE lab;
```

## Errant transactions

An errant transaction is one executed on a replica but not on its primary.
It arrives through a write on the replica (someone switched off
`super_read_only`, or set `sql_log_bin=0` and forgot), or through a replica
initialised with history of its own. It is invisible while the replica
stays a replica. It matters at failover: when this replica becomes the
primary, every other replica connects with auto-positioning, finds GTIDs it
does not have, and fetches them. If they are still in the new primary's
binary logs, they are applied everywhere, a change nobody intended now on
every server. If they have been purged, the other replicas fail to connect
with error 1236, and the failover fails.

Make one, find it, and fix it. The fix is the standard one: once the data
effect has been dealt with, commit an **empty transaction with the same
GTID on the primary**, so that the primary "has" it and it is no longer
errant
([Skipping Transactions With GTIDs](https://dev.mysql.com/doc/refman/8.4/en/replication-administration-skip.html)):

```bash test
primary_set="$(./lab sql primary -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
before="$(./lab sql replica -N -e "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_set')" | tr -d '\n')"

# Someone "just quickly" creates a schema on the replica.
./lab sql replica -e "
  SET GLOBAL super_read_only = OFF;
  CREATE DATABASE scratch_on_replica;
  SET GLOBAL super_read_only = ON;"

after="$(./lab sql replica -N -e "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_set')" | tr -d '\n')"
new="$(./lab sql replica -N -e "SELECT GTID_SUBTRACT('$after', '$before')" | tr -d '\n')"
echo "errant transactions now: $after"
echo "the new one:             $new"

# 1. Undo its effect on the replica, without creating another errant GTID.
./lab sql replica -e "
  SET GLOBAL super_read_only = OFF;
  SET SESSION sql_log_bin = 0;
  DROP DATABASE scratch_on_replica;
  SET GLOBAL super_read_only = ON;"
# 2. Tell the primary about the GTID: an empty transaction.
./lab sql primary -e "SET GTID_NEXT = '$new'; BEGIN; COMMIT; SET GTID_NEXT = 'AUTOMATIC';"

primary_set="$(./lab sql primary -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
echo "errant after the fix:    $(./lab sql replica -N -e \
  "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_set')" | tr -d '\n')"
```

```text
errant transactions now: 2f1e6250-c6fa-11f1-ad34-668f2555875d:1
the new one:             2f1e6250-c6fa-11f1-ad34-668f2555875d:1
errant after the fix:
```

The replica's first transaction under its own UUID was the errant one, and
after the fix nothing is errant: its effect is undone and the primary now
holds an empty transaction with its GTID, which replicates to every replica
as a no-op. The alternative, rewriting the replica's own history with
`RESET BINARY LOGS AND GTIDS` and `SET GLOBAL gtid_purged`, also works but
discards the replica's binary logs; it is the tool for a fresh replica (as
`./lab up` uses it) or for rebuilding one, not for a single repair.

<!-- founder-review: a real failover that went wrong because of errant transactions would make this section land -->

## Replication errors: 1062 and 1032

With row-based replication two applier errors dominate, and both mean the
replica's data has already diverged from the primary's:

- **1062, duplicate key**: the primary inserted a row whose key already
  exists on the replica.
- **1032, row not found** (`HA_ERR_KEY_NOT_FOUND`): the primary updated or
  deleted a row the replica does not have.

The error message names the failing GTID, the table and the binary log
position; `performance_schema.replication_applier_status_by_worker` has it
per worker. The relay log on the replica holds the full row images:
`mysqlbinlog --base64-output=DECODE-ROWS -v` on the relay log file shows
exactly which row the primary changed and what it looked like before.

There are two ways to get the applier past the error, and only one of them
is a fix:

- **Fix the data, then let the applier run the transaction.** Make the
  replica's row match what the primary had before this transaction (delete
  the replica's conflicting row for a 1062, put back the missing row for a
  1032), with `sql_log_bin=0` so the repair does not become an errant
  transaction, then `START REPLICA`. The primary's transaction then applies
  as on the primary, and the data converges.
- **Skip the transaction** by committing an empty transaction with its GTID
  on the replica. Replication runs again, and the replica is now missing
  that change for ever. That is right only when you have established that
  the change's effect is already there (or irrelevant). As a reflex, it
  turns one visible error into silent divergence.

`sql_replica_skip_counter`, the pre-GTID way to skip events, does not work
with GTID auto-positioning: the manual says it "must not be set to a
nonzero value when `gtid_mode=ON`"
([sql_replica_skip_counter](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#sysvar_sql_replica_skip_counter)).
What 8.4.11 actually does is worth seeing, because it does not stop you:

```sql test replica
STOP REPLICA;
SET GLOBAL sql_replica_skip_counter = 1;
SHOW WARNINGS;
START REPLICA;
SELECT @@GLOBAL.sql_replica_skip_counter;
```

```text
+---------+------+----------------------------------------------------------------------------------------------------------------------+
| Level   | Code | Message                                                                                                              |
+---------+------+----------------------------------------------------------------------------------------------------------------------+
| Warning | 4016 | The value of sql_replica_skip_counter will only take effect for channels running with ASSIGN_GTIDS_TO_ANONYMOUS_TRANSACTIONS <> OFF. |
+---------+------+----------------------------------------------------------------------------------------------------------------------+
+-----------------------------------+
| @@GLOBAL.sql_replica_skip_counter |
+-----------------------------------+
|                                 0 |
+-----------------------------------+
```

The `SET` succeeds with a warning, `START REPLICA` resets the counter, and
nothing is skipped. On a broken replica (the `07-broken-replication`
exercise) the applier stops on the same error again. If a runbook says
"set the skip counter", it predates GTIDs.

Finding the cause matters as much as the fix: an errant write on the
replica, a restore loaded with `sql_log_bin=0` (Module 6), a replica built
from an inconsistent backup, or `replica_exec_mode=IDEMPOTENT` hiding
earlier divergence. After any repair, compare the data
(`pt-table-checksum`, or the lab's fingerprint): one error is usually not
the only difference.

## High availability

Replication gives you a copy. High availability is the procedure, and
increasingly the software, that turns the copy into the primary when
needed, without losing transactions and without two primaries.

### Switchover (planned)

A switchover moves the primary role while both servers are healthy, for
maintenance or an upgrade. In outline
([Switching Sources During Failover](https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-switch.html)):

1. Check the candidate: replication running, lag near zero, **no errant
   transactions**, same configuration and capacity as the primary.
2. Stop writes on the old primary: `SET GLOBAL super_read_only = ON`
   (and stop or redirect the application).
3. Wait until the candidate has executed everything:
   `SELECT WAIT_FOR_EXECUTED_GTID_SET('<old primary gtid_executed>', 60)`
   on the candidate returns 0.
4. On the candidate: `STOP REPLICA; RESET REPLICA ALL;` then
   `SET PERSIST super_read_only = OFF, read_only = OFF`.
5. Point the old primary (and every other replica) at the new primary:
   `CHANGE REPLICATION SOURCE TO SOURCE_HOST='<new>', SOURCE_AUTO_POSITION=1, ...;
   START REPLICA;`
6. Move the application: DNS, a proxy, or a virtual IP.
7. Verify: writes arrive, replicas follow, GTID sets agree.

No transaction is lost, because nothing was written between steps 2 and 5.

### Failover (unplanned) and split brain

A failover does the same after the primary has failed, which removes the
guarantees: some transactions committed on the old primary may not have
reached any replica (asynchronous replication), or reached only some of
them. A failover therefore picks the most advanced replica (largest
`gtid_executed`), lets the others catch up from it, and promotes it.

The real danger is the old primary coming back. If it was only partitioned
from the network, not dead, it may still accept writes from clients that
can reach it. Two servers accepting writes is **split brain**: the data
diverges and there is no automatic way to merge it. The defence is
**fencing**: before promoting, make certain the old primary cannot take
writes (power it off through the hypervisor or cloud API, cut its network,
set it `super_read_only` if reachable, or revoke the application's access),
and never let a failed primary rejoin without being rebuilt or checked.
The manual's note on semi-synchronous replication says the same: after a
failover, discard the failed source rather than reuse it.

<!-- founder-review: a short first-hand account of a split-brain or a fencing decision would help here -->

### Tools, briefly

- **Group Replication** replaces asynchronous replication between members
  with a group communication protocol: a transaction commits only when a
  majority of members agree on it, so a minority partition cannot accept
  writes, and the group elects a new primary itself
  ([Group Replication](https://dev.mysql.com/doc/refman/8.4/en/group-replication.html)).
  It needs three or more members, has stricter requirements (every table
  needs a primary key), and is sensitive to network latency.
- **InnoDB Cluster** packages Group Replication with MySQL Shell's
  AdminAPI for setup and MySQL Router for client routing; **InnoDB
  ReplicaSet** does the same for ordinary asynchronous replication, with
  manual failover
  ([InnoDB Cluster](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-innodb-cluster.html),
  [InnoDB ReplicaSet](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-innodb-replicaset.html)).
- **Orchestrator** discovers a replication topology, visualises it, and
  automates failover for asynchronous replication, choosing the best
  replica and repointing the rest
  ([openark/orchestrator](https://github.com/openark/orchestrator)).
- **ProxySQL** sits between the application and MySQL, routes reads and
  writes by rule and by each server's `read_only` state, and so hides a
  primary change from the application
  ([ProxySQL documentation](https://proxysql.com/documentation/)).

None of these removes the need to understand the mechanisms in this
module: when automation hesitates or does the wrong thing, a person reads
the GTID sets and decides.

## Common mistakes and troubleshooting

- **"Both threads say Yes, so replication is fine."** A replica can be
  hours behind with both threads running. Measure with GTIDs or a
  heartbeat.
- **Graphing `Seconds_Behind_Source` alone.** `NULL` when the applier is
  stopped, 0 while the receiver lags, jumps with large transactions.
- **Skipping errors as a reflex.** An empty transaction for a failing GTID
  makes replication run and the data wrong.
- **Writing to a replica**, or running without `super_read_only`. Every
  such write is an errant transaction waiting for the next failover.
- **Repairing a replica with binary logging on.** The repair itself becomes
  an errant transaction; use `SET SESSION sql_log_bin = 0` for the repair.
- **Failing over without fencing.** Promote only when the old primary
  certainly cannot take writes.
- **Large transactions and DDL on the primary during peak**, then surprise
  at replica lag. Batch big deletes; plan DDL with the replica in mind.

## Further reading

- [Replication](https://dev.mysql.com/doc/refman/8.4/en/replication.html) (MySQL 8.4 manual, chapter 19)
- [Replication with Global Transaction Identifiers](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids.html)
- [Replication Threads](https://dev.mysql.com/doc/refman/8.4/en/replication-threads.html) and [Monitoring Replication Applier Worker Threads](https://dev.mysql.com/doc/refman/8.4/en/replication-threads-monitor-worker.html)
- [Semisynchronous Replication](https://dev.mysql.com/doc/refman/8.4/en/replication-semisync.html)
- [Skipping Transactions](https://dev.mysql.com/doc/refman/8.4/en/replication-administration-skip.html)
- [Group Replication](https://dev.mysql.com/doc/refman/8.4/en/group-replication.html)

## Next

Do the [exercise](exercise.md): a replica that falls further behind every
second, and a replica stopped by errors 1062 and 1032. Then check yourself
with the [quiz](quiz.md).

Module 8, [Monitoring and observability](../08-monitoring-observability/README.md),
turns the measurements from this module into alerts.
