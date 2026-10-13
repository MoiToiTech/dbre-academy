# Exercise — Replication lag and broken replication

`time: ~50 min` · `scenarios: 07-replication-lag, 07-broken-replication`

Two incidents a replica owner meets sooner or later. In the first, the
replica falls further behind every second although nothing is wrong with
the primary; waiting will not fix it. In the second, the replica's applier
has stopped on errors, and the obvious fix makes things worse. Do them in
order; each takes 15 to 25 minutes.

## Part 1 — The replica that keeps falling behind

```bash test
./lab scenario setup 07-replication-lag
```

Setup creates `lab.heartbeat` on the primary and starts a loop in the
primary's container that stamps it with `NOW(6)` once a second. On the
replica, `NOW(6)` minus that stamp is the real replication delay. Then it
creates the fault (on the replica; that is all you are told) and makes one
price update on the primary.

```bash test expect-error
./lab check 07-replication-lag
```

```text
Checking 07-replication-lag
  FAIL a session on the replica still holds a global read lock
       hint: what are the applier workers waiting for? SHOW PROCESSLIST on the replica
       hint: performance_schema.metadata_locks: OBJECT_TYPE GLOBAL/COMMIT, who holds them (OWNER_THREAD_ID)?
       hint: KILL QUERY ends a statement, not a session: a lock taken earlier in the session survives it
  PASS receiver/applier threads running
  FAIL the replica is still behind the primary (GTID sets differ)
  FAIL heartbeat delay on the replica is 6.5s (want under 5s)
  FAIL shop differs between primary and replica
4 check(s) failed.
```

The check names the cause in its first line, so try to find it yourself
before you run it. Start where you would in production: how far behind,
and is it the receiver or the applier?

```sql test replica
SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, ts, NOW(6)) / 1e6, 1) AS delay_seconds
  FROM lab.heartbeat;
```

```text
+---------------+
| delay_seconds |
+---------------+
|           7.2 |
+---------------+
```

Run it a few times: the delay grows by a second per second. Now compare it
with what `SHOW REPLICA STATUS` says, and look at the threads:

```bash test
./lab sql replica -e "SHOW REPLICA STATUS\G" | grep -E 'Running:|Seconds_Behind|SQL_Running_State'
./lab sql replica --table -e "
  SELECT GTID_SUBTRACT(RECEIVED_TRANSACTION_SET, @@GLOBAL.gtid_executed) AS received_not_applied
    FROM performance_schema.replication_connection_status;
  SHOW PROCESSLIST;"
```

```text
           Replica_IO_Running: Yes
          Replica_SQL_Running: Yes
        Seconds_Behind_Source: 7
    Replica_SQL_Running_State: Waiting for dependent transaction to commit
+----------------------------------------------+
| received_not_applied                         |
+----------------------------------------------+
| f5295318-c6f6-11f1-90ea-9a823957eb04:150-157 |
+----------------------------------------------+
+-----+-----------------+-----------------+------+---------+------+---------------------------------------------+------------------+
| Id  | User            | Host            | db   | Command | Time | State                                       | Info             |
+-----+-----------------+-----------------+------+---------+------+---------------------------------------------+------------------+
...
|  84 | system user     |                 | NULL | Query   |    6 | Waiting for dependent transaction to commit | NULL             |
|  85 | system user     |                 | NULL | Query   |    7 | Waiting for global read lock                | NULL             |
...
|  95 | root            | localhost       | NULL | Query   |    7 | User sleep                                  | DO SLEEP(86400)  |
...
```

Both threads say `Yes`. Eight transactions have arrived in the relay log
and not been applied, and the number grows: this is applier lag, not
network lag, and a worker tells you what it waits for.

### Your task

1. Find the session that holds what the applier is waiting for. The
   lesson's lag section lists the usual suspects;
   `performance_schema.metadata_locks` shows who holds a lock
   (`OWNER_THREAD_ID`, which `performance_schema.threads` maps to a
   processlist id).
2. Remove the cause. Think about what this session probably was and what
   ending it costs.
3. Watch the heartbeat delay fall to under a second, and the GTID sets
   meet.

<details>
<summary>Hint 1</summary>

`Waiting for global read lock` means someone ran
`FLUSH TABLES WITH READ LOCK`, the lock that backup tools take for
consistent coordinates (Module 6). Look for `OBJECT_TYPE = 'GLOBAL'` and
`'COMMIT'` with `LOCK_STATUS = 'GRANTED'`.

</details>

<details>
<summary>Hint 2</summary>

`KILL QUERY` ends only the running statement (the `SLEEP`); the lock
belongs to the session and survives. `KILL <id>` ends the connection and
releases the lock.

</details>

A reference solution is in `labs/scenarios/07-replication-lag/solve.sh`.

```text
$ ./lab check 07-replication-lag
Checking 07-replication-lag
  PASS no session holds a global read lock on the replica
  PASS receiver/applier threads running
  PASS the replica has executed every transaction the primary has
  PASS heartbeat delay on the replica is 0.8s
  PASS shop has identical content on primary and replica
All checks passed.
```

Afterwards, think about the real-world version: a nightly backup on the
replica hung with the lock held. What should have alerted you, and what
should the backup job have done differently? (Module 6, "Consistency".)

```bash test
./lab scenario reset 07-replication-lag
```

## Part 2 — The replica that stopped

```bash test
./lab scenario setup 07-broken-replication
```

Monitoring says the replica stopped applying changes this morning.
"Nobody has touched it", they say.

```bash test expect-error
./lab check 07-broken-replication
```

```text
Checking 07-broken-replication
  FAIL replication is not running cleanly (receiver/applier: ON/OFF, workers with errors: 1)
       hint: performance_schema.replication_applier_status_by_worker has the full error per worker
  FAIL the replica is missing transactions the primary has executed
  FAIL errant transactions on the replica: 2f1e6250-c6fa-11f1-ad34-668f2555875d:2-3
       hint: the replica executed these, the primary never did; a failover would ship them to every other replica
       hint: once their effect on the data is dealt with, make the primary know them (empty transactions)
  FAIL shop differs between primary and replica
       ...
  PASS replica super_read_only is ON
4 check(s) failed.
```

The goal is more than "both threads running":

- the receiver and applier run without errors;
- the replica has every transaction the primary has;
- the replica has **no errant transactions** created since setup (any that
  existed before setup are outside this exercise);
- `shop` is identical on both servers;
- `super_read_only` is still `ON`.

Start with the error, per worker:

```sql test replica
SELECT WORKER_ID, LAST_ERROR_NUMBER, APPLYING_TRANSACTION, LAST_ERROR_MESSAGE
  FROM performance_schema.replication_applier_status_by_worker
 WHERE LAST_ERROR_NUMBER <> 0\G
```

```text
*************************** 1. row ***************************
           WORKER_ID: 1
   LAST_ERROR_NUMBER: 1062
APPLYING_TRANSACTION: 2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1261
  LAST_ERROR_MESSAGE: Worker 1 failed executing transaction
  '2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1261' at source log binlog.000008,
  end_log_pos 180894107; Could not execute Write_rows event on table
  shop.customers; Duplicate entry '20001' for key 'customers.PRIMARY', ...
```

What exactly did the primary try to do? The relay log holds the row
images. `mysqlbinlog` on the replica's relay log, filtered to the failing
GTID:

```bash test
./lab shell replica <<'SH'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
gtid="$(mysql -uroot -N -e "SELECT APPLYING_TRANSACTION
          FROM performance_schema.replication_applier_status_by_worker
         WHERE LAST_ERROR_NUMBER <> 0 LIMIT 1")"
echo "failing transaction: $gtid"
cd /var/lib/mysql
mysqlbinlog --include-gtids="$gtid" --base64-output=DECODE-ROWS -vv relay.[0-9]* | grep '^###'
SH
```

```text
failing transaction: 2f1ddfc8-c6fa-11f1-b057-da1ec2050429:1261
### INSERT INTO `shop`.`customers`
### SET
###   @1=20001 /* INT meta=0 nullable=0 is_null=0 */
###   @2='customer20001@example.test' /* VARSTRING(1020) meta=1020 nullable=0 is_null=0 */
###   @3='Liis Kask' /* VARSTRING(400) meta=400 nullable=0 is_null=0 */
###   @4='LV' /* STRING(8) meta=65032 nullable=0 is_null=0 */
###   @5=1 /* ENUM(1 byte) meta=63233 nullable=0 is_null=0 */
###   @6='2026-03-02 08:12:00' /* DATETIME(0) meta=0 nullable=0 is_null=0 */
```

Columns appear as `@1`, `@2`, ... in table order, because
`binlog_row_metadata=MINIMAL` (the default) does not log column names.
Compare with the row the replica already has, and with the replica's own
transactions:

```bash test
./lab sql replica --table -e "SELECT * FROM shop.customers WHERE id = 20001"
primary_set="$(./lab sql primary -N -e 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
./lab sql replica --table -e "
  SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_set') AS errant"
```

```text
+-------+----------------------------+--------------+--------------+--------+---------------------+
| id    | email                      | full_name    | country_code | status | created_at          |
+-------+----------------------------+--------------+--------------+--------+---------------------+
| 20001 | customer20001@example.test | Test Account | EE           | active | 2026-03-01 23:40:00 |
+-------+----------------------------+--------------+--------------+--------+---------------------+
+------------------------------------------+
| errant                                   |
+------------------------------------------+
| 2f1e6250-c6fa-11f1-ad34-668f2555875d:2-3 |
+------------------------------------------+
```

Your numbers differ. Here the replica's own transaction `1` was the
lesson's demonstration, already repaired: the primary knows it, so it is
not listed. `2-3` are new since setup. A lab built
by `./lab up` starts with none: it clears the replica's own initialisation
transactions before configuring replication.

"Nobody has touched it." Read the replica's own binary log for those
transactions (`./lab shell replica`, then `mysqlbinlog` on
`/var/lib/mysql/binlog.*` with `--include-gtids`) to see what was done and
when.

### Your task

1. Find out what was written on the replica and what the primary tried to
   do. Expect more than one problem: fix the first and the applier may stop
   on the next.
2. Repair the replica's data so that each failing transaction can apply
   **as it did on the primary**. The primary is the source of truth.
3. Deal with the errant transactions so the replica has nothing the
   primary lacks.
4. Restart replication and verify: `./lab status`, the GTID comparison
   above, `./lab fingerprint primary` vs `./lab fingerprint replica`.

Before you start, two things that look like fixes and are not:

- `SET GLOBAL sql_replica_skip_counter = 1` does nothing with GTID
  auto-positioning (lesson, "Replication errors").
- Committing an empty transaction with the failing GTID on the replica
  gets replication running and leaves the replica with the wrong customer
  20001 for ever. The check will tell you.

<details>
<summary>Hint 1 — repairing without creating more errant transactions</summary>

Any write you make on the replica with binary logging on gets a new GTID
with the replica's UUID: another errant transaction. Do repairs in a
session with `SET SESSION sql_log_bin = 0`, and remember that
`super_read_only` blocks even root until you switch it off (and back on).

</details>

<details>
<summary>Hint 2 — error 1032</summary>

The primary updated a row the replica does not have. The failing event's
before image (`### WHERE` section in `mysqlbinlog -vv`) shows the row as
it was on the primary before the update. Insert that row on the replica,
without binary logging, and let the applier run the update.

</details>

<details>
<summary>Hint 3 — the errant GTIDs</summary>

Once their effect on the data is gone, commit one empty transaction per
errant GTID **on the primary**:
`SET GTID_NEXT = '<uuid>:<n>'; BEGIN; COMMIT; SET GTID_NEXT = 'AUTOMATIC';`

</details>

A reference solution is in `labs/scenarios/07-broken-replication/solve.sh`.

```text
$ ./lab check 07-broken-replication
Checking 07-broken-replication
  PASS receiver and applier threads are running without errors
  PASS the replica has executed every transaction the primary has
  PASS no errant transactions on the replica
  PASS shop has identical content on primary and replica
  PASS replica super_read_only is ON
All checks passed.
```

Questions for yourself:

- If this replica had been promoted during the night, before anyone saw
  the error, what would the other replicas have received?
- Which single setting would have prevented the whole incident, and who
  switched it off?

```bash test
./lab scenario reset 07-broken-replication
```

Reset reloads the canonical dataset on the primary and, if the replica is
stopped, divergent or carries errant transactions from the scenario,
rebuilds it from a dump of the primary.
