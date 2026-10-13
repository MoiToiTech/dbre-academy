# Module 6 — Backup, restore and data integrity

`time: ~90 min` · `lab: ./lab scenario setup 06-pitr` · `level: fundamentals`

Nobody is ever asked for a backup. They are asked for a restore: the table
someone dropped, the rows a deploy corrupted, the server whose disk died.
A backup that has never been restored is a hope, not a backup. This module
covers the methods MySQL 8.4 gives you, what each one guarantees about
consistency, how the binary log turns last night's backup into "five
minutes before the accident", and how to prove that a backup works.

## Learning objectives

By the end of this module you can:

- turn an RPO and an RTO into a choice of backup method;
- take a consistent logical backup with `mysqldump` and with MySQL Shell,
  and explain what `--single-transaction` does and does not cover;
- say what each `--set-gtid-purged` value writes into a dump, and pick the
  right one for the restore you are planning;
- describe physical backups (Percona XtraBackup, the CLONE plugin) and
  storage snapshots, and take a physical copy with CLONE;
- recover to a point in time with `mysqlbinlog`, skipping one transaction,
  on a server that uses GTIDs;
- verify a backup by restoring it and comparing fingerprints, and check
  tables with `CHECK TABLE` and `mysqlcheck`;
- set retention, off-host copies and encryption for backups.

## Prerequisites

- The lab is running: `./lab up`. Commands run from the `labs/` directory.
- Module 1 (the binary log and the redo log) and Module 3 (transactions and
  consistent reads).

This module runs tools inside the primary's container with
`./lab shell primary`, feeding it a script on standard input. Inside the
container `$MYSQL_ROOT_PASSWORD` holds the lab's root password; the scripts
copy it into `MYSQL_PWD` so that it does not appear on a command line. The
`backups` volume is mounted at `/backups` in both MySQL containers.

## RPO and RTO choose the method

Two numbers, agreed with whoever owns the data, decide everything else:

- **RPO** (recovery point objective): how much committed work you may lose.
  "Last night's backup" is an RPO of up to 24 hours.
- **RTO** (recovery time objective): how long the restore may take, from
  "we need it back" to "the application works again".

| Method | Typical RPO | RTO driver |
|---|---|---|
| Logical dump only | Time since the dump | Re-executing every row and rebuilding every index |
| Physical backup only | Time since the backup | Copying files back, crash recovery |
| Either + binary logs | Seconds (last binlog copied off-host) | Restore, then replay of the binlogs |
| Replica / snapshot | Seconds, but copies mistakes too | Promotion or snapshot mount |

The row that matters is the third. A full backup alone has an RPO equal to
the backup interval. A full backup plus every binary log written since has
an RPO of however much binary log you have not yet copied somewhere safe
([Backup and Recovery Types](https://dev.mysql.com/doc/refman/8.4/en/backup-types.html),
[Point-in-Time Recovery](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery.html)).
A replica is not a backup: an accidental `DELETE` reaches it within
milliseconds.

The binary log configuration is therefore part of the backup design. Check
what the lab keeps:

```sql test
SELECT @@log_bin, @@binlog_format, @@gtid_mode, @@sync_binlog,
       @@binlog_expire_logs_seconds / 86400 AS binlog_retention_days;
SHOW BINARY LOGS;
```

```text
+-----------+-----------------+-------------+---------------+-----------------------+
| @@log_bin | @@binlog_format | @@gtid_mode | @@sync_binlog | binlog_retention_days |
+-----------+-----------------+-------------+---------------+-----------------------+
|         1 | ROW             | ON          |             1 |                7.0000 |
+-----------+-----------------+-------------+---------------+-----------------------+
+---------------+-----------+-----------+
| Log_name      | File_size | Encrypted |
+---------------+-----------+-----------+
| binlog.000001 |       181 | No        |
| binlog.000002 |   2983175 | No        |
| binlog.000003 |  60190747 | No        |
+---------------+-----------+-----------+
```

Seven days of binary logs (`binlog_expire_logs_seconds`; the 8.4 default
is 30 days) means a point-in-time restore can only start from a full
backup taken within the last seven days. Your backup interval must be
shorter than your binlog retention, with margin for a backup that failed.
`sync_binlog = 1` means a committed transaction is in the binary log on
disk before the client hears "OK"
([Binary Logging Options](https://dev.mysql.com/doc/refman/8.4/en/replication-options-binary-log.html)).
The file sizes on your lab differ if you have run other modules.

<!-- founder-review: a real example of RPO/RTO being agreed (or never agreed) with a client, and what that changed in the backup design, would help here -->

## Logical backups with mysqldump

A logical backup is SQL: `CREATE TABLE` and `INSERT` statements that
rebuild the data on any MySQL server
([Using mysqldump for Backups](https://dev.mysql.com/doc/refman/8.4/en/using-mysqldump.html)).
It is portable across versions and platforms and you can restore one table
from it. Its cost is the restore: every row is re-inserted and every index
rebuilt, so a dump that took ten minutes can take hours to load.

The flags that matter for a production dump:

| Flag | Why |
|---|---|
| `--single-transaction` | Consistent InnoDB snapshot without blocking writers |
| `--source-data=2` | Records the binlog file and position, as a comment |
| `--routines --events --triggers` | Stored programs; routines and events are off by default |
| `--set-gtid-purged=...` | What to do with the GTID set; see below |

```bash test
./lab shell primary <<'SH'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
mkdir -p /backups/m06
mysqldump -uroot --single-transaction --source-data=2 --routines --events --triggers \
  --set-gtid-purged=ON --databases shop > /backups/m06/shop.sql
ls -lh /backups/m06/shop.sql
grep -nE 'GTID_PURGED|SQL_LOG_BIN|CHANGE REPLICATION SOURCE' /backups/m06/shop.sql
SH
```

```text
Warning: A partial dump from a server that has GTIDs will by default include
the GTIDs of all transactions, even those that changed suppressed parts of
the database. ...
-rw-r--r-- 1 root root 39M Oct 13 11:09 /backups/m06/shop.sql
17:SET @MYSQLDUMP_TEMP_LOG_BIN = @@SESSION.SQL_LOG_BIN;
18:SET @@SESSION.SQL_LOG_BIN= 0;
24:SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:1-34';
30:-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=60190747;
261:SET @@SESSION.SQL_LOG_BIN = @MYSQLDUMP_TEMP_LOG_BIN;
```

Line 30 is the point in the binary log that the snapshot corresponds to.
It is the starting point for every point-in-time recovery from this dump;
keep it. Line 24 is the GTID set the server had executed at that moment.

### `--set-gtid-purged`: decide what the restore should do

On a server with `gtid_mode=ON`, the dump can carry the source's
`gtid_executed` set. What lands in the file depends on the value
([mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html)):

| Value | `SET @@GLOBAL.GTID_PURGED` | `SQL_LOG_BIN=0` |
|---|---|---|
| `AUTO` (default), `ON` | Yes | Yes |
| `COMMENTED` | Yes, commented out | Yes |
| `OFF` | No | No |

The same dump, three ways, so you can see it rather than take it on trust:

```bash test
./lab shell primary <<'SH'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
for mode in ON COMMENTED OFF; do
  echo "== --set-gtid-purged=$mode"
  mysqldump -uroot --single-transaction --set-gtid-purged=$mode --databases shop \
    2>/dev/null | grep -E 'GTID_PURGED|SQL_LOG_BIN= 0' || echo "(neither)"
done
SH
```

```text
== --set-gtid-purged=ON
SET @@SESSION.SQL_LOG_BIN= 0;
SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:1-34';
== --set-gtid-purged=COMMENTED
SET @@SESSION.SQL_LOG_BIN= 0;
/* SET @@GLOBAL.GTID_PURGED='+86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:1-34';*/
== --set-gtid-purged=OFF
(neither)
```

Note that `COMMENTED` still switches binary logging off for the load. The
consequences:

- **`ON`/`AUTO`: building a new replica.** The load is not binary-logged,
  and the new server records the source's GTIDs as already executed, so
  `SOURCE_AUTO_POSITION=1` starts replication from exactly the right place.
  Loading it on a server that has already executed those GTIDs fails at the
  `GTID_PURGED` line.
- **`OFF`: restoring into a live, replicated primary.** The load is an
  ordinary, binary-logged set of transactions with new GTIDs, so the
  replicas apply it too. Restore an `ON` dump on a replicated primary and
  the primary changes while its replicas do not.

Choose per backup purpose, and write the purpose down next to the backup.
The `06-pitr` exercise uses an `OFF` dump for exactly this reason.

### Consistency: what `--single-transaction` covers

`--single-transaction` starts a `REPEATABLE READ` transaction with a
consistent snapshot and dumps every table from it. Writers are not blocked.
The manual is explicit about the limits: only InnoDB tables are dumped
consistently, and DDL (`ALTER`, `DROP`, `RENAME`, `TRUNCATE TABLE`) on a
table being dumped can make the dump wrong or make it fail
([mysqldump --single-transaction](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html#option_mysqldump_single-transaction)).
To read binary log coordinates that match the snapshot, `--source-data`
takes `FLUSH TABLES WITH READ LOCK` (FTWRL) for a moment at the start
([mysqldump --source-data](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html#option_mysqldump_source-data)).
FTWRL has to wait for every running statement to finish, and everything
else waits behind it: on a server with a ten-minute report running, "a
moment" is ten minutes of blocked writes.

Before trusting `--single-transaction`, check that every table it will dump
is InnoDB:

```sql test
SELECT TABLE_SCHEMA, ENGINE, COUNT(*) AS tables
  FROM information_schema.TABLES
 WHERE TABLE_TYPE = 'BASE TABLE'
   AND TABLE_SCHEMA NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
 GROUP BY TABLE_SCHEMA, ENGINE;
```

```text
+--------------+--------+--------+
| TABLE_SCHEMA | ENGINE | tables |
+--------------+--------+--------+
| shop         | InnoDB |      6 |
+--------------+--------+--------+
```

A MyISAM or MEMORY row in that output means the dump of that table is not
consistent with the rest.

### MySQL Shell: the parallel option

`mysqldump` is single-threaded on dump and on load. MySQL Shell's
`util.dumpInstance()`, `util.dumpSchemas()` and `util.dumpTables()` dump in
parallel chunks to compressed files, and `util.loadDump()` loads them in
parallel, deferring secondary indexes
([Instance and Schema Dump Utility](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-dump-instance-schema.html),
[Dump Loading Utility](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-load-dump.html)).
For anything beyond a few gigabytes, this is the logical tool to reach for.
`mysqlsh` is in the lab image:

```bash test
./lab shell primary <<'SH'
mkdir -p /tmp/mysqlsh; export MYSQLSH_USER_CONFIG_HOME=/tmp/mysqlsh
mysqlsh --uri root@127.0.0.1:3306 --password="$MYSQL_ROOT_PASSWORD" --js \
  -e "util.dumpSchemas(['shop'], '/backups/m06/shell-dump', {threads: 4})" 2>&1 \
  | grep -vE 'locale|password on the command line'
SH
```

```text
Acquiring global read lock
Global read lock acquired
Initializing - done
Gathering information...
1 schemas will be dumped and within them 6 tables, 0 views.
Gathering information - done
All transactions have been started
Locking instance for backup
Global read lock has been released
...
Running data dump using 4 threads.
...
Schemas dumped: 1
Tables dumped: 6
Uncompressed data size: 36.00 MB
Compressed data size: 10.04 MB
Compression ratio: 3.6
Rows written: 918021
```

The log shows the consistency mechanism: FTWRL while each thread starts its
consistent-snapshot transaction, then `LOCK INSTANCE FOR BACKUP` (which
blocks DDL but not DML) for the rest of the dump
([LOCK INSTANCE FOR BACKUP](https://dev.mysql.com/doc/refman/8.4/en/lock-instance-for-backup.html)).
The binary log coordinates and GTID set of the snapshot are in the dump's
`@.json` file.

`util.loadDump()` uses `LOAD DATA LOCAL INFILE`, so the target needs
`local_infile=ON` for the duration of the load. The lab keeps it off, so
switch it on, load the dump into a scratch schema, compare, and switch it
off again:

```bash test
./lab sql primary -e "SET GLOBAL local_infile = ON"
./lab shell primary <<'SH'
mkdir -p /tmp/mysqlsh; export MYSQLSH_USER_CONFIG_HOME=/tmp/mysqlsh
mysqlsh --uri root@127.0.0.1:3306 --password="$MYSQL_ROOT_PASSWORD" --js \
  -e "util.loadDump('/backups/m06/shell-dump', {schema: 'lab', threads: 4})" 2>&1 \
  | grep -E 'chunks|warnings'
SH
./lab sql primary -e "SET GLOBAL local_infile = OFF"
```

```text
6 chunks (918.02K rows, 36.00 MB) for 6 tables in 1 schemas were loaded in 1 sec ...
0 warnings were reported during the load.
```

```sql test
SELECT (SELECT COUNT(*) FROM lab.payments) AS restored_rows,
       (SELECT SUM(CRC32(CONCAT_WS('|', id, order_id, method, amount_cents, status, created_at)))
          FROM lab.payments)
     = (SELECT SUM(CRC32(CONCAT_WS('|', id, order_id, method, amount_cents, status, created_at)))
          FROM shop.payments) AS checksums_match;
DROP DATABASE lab;
```

```text
+---------------+-----------------+
| restored_rows | checksums_match |
+---------------+-----------------+
|        194021 |               1 |
+---------------+-----------------+
```

`mysqlpump`, which some older guides recommend, was removed in MySQL 8.4.

## Physical backups and snapshots

A physical backup copies InnoDB's files rather than its rows. The restore
is a file copy plus crash recovery, so the RTO scales with disk throughput,
not with the number of rows and indexes. The price: same major version,
same platform family, and no restoring a single table without extra work.

### Percona XtraBackup

XtraBackup is the established open-source hot physical backup tool for
MySQL. It copies the data files while the server runs, and at the same time
follows the redo log and copies every change made during the copy. The
copied files are internally inconsistent; the **prepare** step runs InnoDB
crash recovery over them, applying the copied redo, which makes them
consistent as of the end of the backup
([How Percona XtraBackup works](https://docs.percona.com/percona-xtrabackup/8.4/how-xtrabackup-works.html),
[Prepare a full backup](https://docs.percona.com/percona-xtrabackup/8.4/prepare-full-backup.html)).
With MySQL 8.4 it uses `LOCK INSTANCE FOR BACKUP` rather than FTWRL where it
can. Use the XtraBackup 8.4 series for MySQL 8.4 servers; the series is
tied to the server series. It also supports incremental backups and
encryption. It is not in the lab image, and nothing in this course requires
it.

### The CLONE plugin: the built-in physical copy

MySQL 8.4 ships a physical copy of its own: the clone plugin. `CLONE LOCAL
DATA DIRECTORY` copies the InnoDB data, the system and undo tablespaces and
the redo log into a new directory, consistently, while the server runs
([Cloning Data Locally](https://dev.mysql.com/doc/refman/8.4/en/clone-plugin-local.html)).
`CLONE INSTANCE FROM` does the same over the network and is how InnoDB
Cluster provisions new members. Its limits, from the
[manual](https://dev.mysql.com/doc/refman/8.4/en/clone-plugin-limitations.html):
it clones only InnoDB data (MyISAM and CSV tables arrive empty), it does
not clone binary logs or configuration, and donor and recipient must be in
the same release series. Concurrent DDL is allowed by default
(`clone_block_ddl=OFF`).

The server process writes the clone, so the target's parent directory must
be writable by `mysql`:

```bash test
./lab shell primary <<'SH'
mkdir -p /backups/m06 && chown mysql:mysql /backups/m06
SH
./lab sql primary --table <<'SQL'
INSTALL PLUGIN clone SONAME 'mysql_clone.so';
CLONE LOCAL DATA DIRECTORY = '/backups/m06/clone';
SELECT STAGE, STATE, ROUND(DATA / 1024 / 1024) AS data_mb
  FROM performance_schema.clone_progress;
SQL
```

```text
+-----------+-------------+---------+
| STAGE     | STATE       | data_mb |
+-----------+-------------+---------+
| DROP DATA | Completed   |       0 |
| FILE COPY | Completed   |     272 |
| PAGE COPY | Completed   |       0 |
| REDO COPY | Completed   |      36 |
| FILE SYNC | Completed   |       0 |
| RESTART   | Not Started |       0 |
| RECOVERY  | Not Started |       0 |
+-----------+-------------+---------+
```

A local clone is a usable data directory. Whether it is a usable *backup*
is a different question, and the next section answers it the only way that
counts.

### Storage snapshots

LVM, ZFS, or a cloud volume snapshot freezes a block device in an instant.
If the snapshot covers everything InnoDB needs (data files, redo log, undo
tablespaces) atomically, it is crash-consistent: starting MySQL on it is
the same as starting after a power cut, and InnoDB recovery makes it
consistent. With several volumes, the snapshot must be atomic across all of
them, or it is not consistent at all. The manual describes the conservative
version: `FLUSH TABLES WITH READ LOCK`, snapshot, `UNLOCK TABLES`
([Database Backup Methods](https://dev.mysql.com/doc/refman/8.4/en/backup-methods.html)).
Snapshots are fast to take and fast to restore, and they live on the same
storage system as the data until you copy them elsewhere.

<!-- founder-review: a first-hand story of a snapshot-based restore (cross-volume consistency, or snapshot restore time on a cloud disk) would help here -->

## Restore testing: the only proof

A backup is good when it has been restored and the restored data has been
checked. Everything before that is a file of unknown value. Restore-test
the clone you just took: start a throwaway MySQL server on it, in its own
container, and compare its fingerprint with the primary's.
`datasets/shop/fingerprint.sql` prints a row count and an order-independent
checksum for every shop table:

```bash test
name="${DBRE_PROJECT:-dbre}-restore-test"
docker run -d --name "$name" -v "${DBRE_PROJECT:-dbre}_backups:/backups" \
  dbre-academy/mysql:8.4 mysqld --datadir=/backups/m06/clone --skip-log-bin >/dev/null
for _ in $(seq 60); do
  docker exec -e MYSQL_PWD="${DBRE_ROOT_PASSWORD:-dbre-lab-root}" "$name" \
    mysqladmin -uroot -h127.0.0.1 ping --silent >/dev/null 2>&1 && break
  sleep 1
done
restored="$(docker exec -i -e MYSQL_PWD="${DBRE_ROOT_PASSWORD:-dbre-lab-root}" "$name" mysql -uroot -t \
             < datasets/shop/fingerprint.sql)"
docker rm -f "$name" >/dev/null
diff <(echo "$restored") <(./lab fingerprint primary) && echo "restore test passed: fingerprints match"
```

```text
restore test passed: fingerprints match
```

The clone started, InnoDB recovered it, and every table has the same rows
and checksums as the source. That is a tested backup. In production the
same test runs on a schedule, on a separate host, and alerts when it fails
or when it has not run. Record how long the restore took: that is your
measured RTO, not your estimated one.

<!-- founder-review: how MoiToi.TECH schedules and alerts on restore tests for clients would make this concrete -->

Clean up the clone and the plugin:

```bash test
./lab sql primary -e "UNINSTALL PLUGIN clone"
./lab shell primary <<'SH'
rm -rf /backups/m06/clone
SH
```

## Binary logs: the bridge to a point in time

The binary log records every committed change, in commit order, with its
GTID. Replaying it from the backup's coordinates up to just before the
accident brings the restored data forward to that moment
([Point-in-Time Recovery Using Binary Log](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery-binlog.html)).
`mysqlbinlog` selects what to replay:

| Option | Selects |
|---|---|
| `--start-position` / `--stop-position` | Byte positions; first / last file only |
| `--start-datetime` / `--stop-datetime` | Event timestamps |
| `--include-gtids` / `--exclude-gtids` | Whole transactions by GTID |
| `--skip-gtids` | Omits the GTIDs from the output |

([mysqlbinlog](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html))

Walk through a small recovery. Create a table, back it up, then write,
make a mistake, and write again:

```bash test
./lab sql primary <<'SQL'
CREATE DATABASE lab;
CREATE TABLE lab.notes (id INT PRIMARY KEY, body VARCHAR(40) NOT NULL);
INSERT INTO lab.notes VALUES (1, 'before the backup');
SQL
./lab shell primary <<'SH'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
mysqldump -uroot --single-transaction --source-data=2 --set-gtid-purged=OFF \
  --databases lab > /backups/m06/lab.sql
grep -m1 'CHANGE REPLICATION SOURCE' /backups/m06/lab.sql
SH
./lab sql primary <<'SQL'
INSERT INTO lab.notes VALUES (2, 'after the backup');
DELETE FROM lab.notes;
INSERT INTO lab.notes VALUES (3, 'after the accident');
SQL
```

```text
-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000003', SOURCE_LOG_POS=83016800;
```

Find the bad transaction. With row-based logging the binary log holds row
images, not SQL; `--base64-output=DECODE-ROWS -v` turns them into readable
pseudo-SQL. Every transaction starts with `SET @@SESSION.GTID_NEXT`:

```bash test
./lab shell primary <<'SH'
cd /var/lib/mysql
coords="$(grep -m1 'CHANGE REPLICATION SOURCE' /backups/m06/lab.sql)"
file="$(sed -E "s/.*SOURCE_LOG_FILE='([^']+)'.*/\1/" <<<"$coords")"
pos="$(sed -E 's/.*SOURCE_LOG_POS=([0-9]+);/\1/' <<<"$coords")"
mysqlbinlog --start-position="$pos" --base64-output=DECODE-ROWS -v "$file" \
  | grep -E 'GTID_NEXT|^### (INSERT|DELETE)'
SH
```

```text
SET @@SESSION.GTID_NEXT= '86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:52'/*!*/;
### INSERT INTO `lab`.`notes`
SET @@SESSION.GTID_NEXT= '86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:53'/*!*/;
### DELETE FROM `lab`.`notes`
### DELETE FROM `lab`.`notes`
SET @@SESSION.GTID_NEXT= '86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:54'/*!*/;
### INSERT INTO `lab`.`notes`
SET @@SESSION.GTID_NEXT= 'AUTOMATIC' /* added by mysqlbinlog */ /*!*/;
```

Transaction `:53` deleted two rows. Now restore and replay. The restore
here goes into the same server, and that has a GTID consequence worth
seeing for yourself: the server has already executed `:52` and `:54`, and a
GTID-enabled server silently skips any transaction whose GTID is in
`gtid_executed`
([GTID auto-skip](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-concepts.html)).
The first replay below keeps the GTIDs; the second drops them with
`--skip-gtids`:

```bash test
./lab shell primary <<'SH'
export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
cd /var/lib/mysql
coords="$(grep -m1 'CHANGE REPLICATION SOURCE' /backups/m06/lab.sql)"
file="$(sed -E "s/.*SOURCE_LOG_FILE='([^']+)'.*/\1/" <<<"$coords")"
pos="$(sed -E 's/.*SOURCE_LOG_POS=([0-9]+);/\1/' <<<"$coords")"
bad="$(mysqlbinlog --start-position="$pos" --base64-output=DECODE-ROWS -v "$file" \
       | awk -F"'" '/GTID_NEXT=/ { g = $2 } /^### DELETE FROM `lab`.`notes`/ && !n++ { print g }')"
echo "skipping $bad"

# Close the current binlog, so the restore below is not in the replay window.
mysql -uroot -e "FLUSH BINARY LOGS"
mysql -uroot < /backups/m06/lab.sql

echo "-- replay keeping the original GTIDs"
mysqlbinlog --start-position="$pos" --exclude-gtids="$bad" "$file" | mysql -uroot
mysql -uroot -t -e "SELECT * FROM lab.notes"

echo "-- replay with --skip-gtids"
mysqlbinlog --start-position="$pos" --exclude-gtids="$bad" --skip-gtids "$file" | mysql -uroot
mysql -uroot -t -e "SELECT * FROM lab.notes"
SH
```

```text
skipping 86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:53
-- replay keeping the original GTIDs
+----+-------------------+
| id | body              |
+----+-------------------+
|  1 | before the backup |
+----+-------------------+
-- replay with --skip-gtids
+----+--------------------+
| id | body               |
+----+--------------------+
|  1 | before the backup  |
|  2 | after the backup   |
|  3 | after the accident |
+----+--------------------+
```

The first replay "succeeded" and changed nothing: no error, no warning.
The second applied rows 2 and 3 as new transactions and left out the
`DELETE`. Two rules come out of this:

- **Know which GTIDs the target has executed.** Restoring onto a fresh
  server (a new instance, a clone, an XtraBackup restore) leaves the
  target with the backup's GTID set, so replaying with the original GTIDs
  works and preserves them. This is the case the manual's procedure
  assumes, and the right one when you can afford a separate server.
- **Restoring in place on a server that already ran those transactions**
  needs `--skip-gtids`. The manual warns against `--skip-gtids` in recovery
  "except in the specific, and rare, scenarios where the GTIDs are actively
  unwanted"
  ([mysqlbinlog --skip-gtids](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html#option_mysqlbinlog_skip-gtids)).
  In place is that scenario: the original GTIDs are unwanted because they
  are already executed. The repair becomes new transactions on top of an
  honest history, and replicas apply them like any other write.

`--exclude-gtids` removes a whole transaction, which is what you want: a
position range can split a transaction, a GTID cannot. Use
`--start-position` / `--stop-position` when GTIDs are off or when you need
to stop inside a stream rather than skip one transaction
([Point-in-Time Recovery Using Event Positions](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery-positions.html)).
Before any of this, copy the binary logs off the server: during an incident
they are the only record of what happened.

```sql test
DROP DATABASE lab;
```

## Verification: checksums, CHECK TABLE, mysqlcheck

Three different questions, three tools:

- **Is the data the data I expect?** Row counts and checksums compared with
  a known-good copy. The lab's fingerprint is one; `pt-table-checksum` does
  the same across a replication topology. `CHECKSUM TABLE` works too, but
  its value depends on row format and server version.
- **Is the table physically sound?** `CHECK TABLE` reads InnoDB's pages and
  indexes and reports corruption
  ([CHECK TABLE](https://dev.mysql.com/doc/refman/8.4/en/check-table.html)).
- **Is every table sound?** `mysqlcheck` runs `CHECK TABLE` over schemas
  from the shell, for scripts and cron
  ([mysqlcheck](https://dev.mysql.com/doc/refman/8.4/en/mysqlcheck.html)).

```sql test
CHECK TABLE shop.orders, shop.payments;
```

```text
+---------------+-------+----------+----------+
| Table         | Op    | Msg_type | Msg_text |
+---------------+-------+----------+----------+
| shop.orders   | check | status   | OK       |
| shop.payments | check | status   | OK       |
+---------------+-------+----------+----------+
```

```bash test
./lab shell primary <<'SH'
MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqlcheck -uroot --check shop
SH
```

```text
shop.customers                                     OK
shop.inventory                                     OK
shop.order_items                                   OK
shop.orders                                        OK
shop.payments                                      OK
shop.products                                      OK
```

`CHECK TABLE` on a large InnoDB table takes time and holds locks; run it on
a restore-test server rather than on the primary. A `status OK` says the
pages are intact, not that the rows are the right rows: that is what the
fingerprint is for.

## Retention, off-host copies and encryption

- **Retention** is a schedule, not a number: for example 14 daily, 8
  weekly and 12 monthly fulls, plus continuous binary logs back to the
  oldest full you would restore from. Binlogs older than your oldest full
  are useless for point-in-time recovery; fulls without binlogs give you
  only their own instant.
- **Off-host and off-account.** A backup on the database host dies with
  the host. A backup in the same cloud account dies with a compromised
  account, and ransomware deletes the backups first. Keep at least one copy
  in a separate account or with object lock (write-once). Stream binary
  logs off the host continuously: `mysqlbinlog --read-from-remote-server
  --raw --stop-never` keeps a live copy on another machine
  ([Using mysqlbinlog to Back Up Binary Log Files](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog-backup.html)).
- **Encryption.** A dump is your whole database in plain text. Encrypt it
  before it leaves the host, with the key stored somewhere else (a KMS or
  secrets manager). XtraBackup has `--encrypt`
  ([Encrypt backups](https://docs.percona.com/percona-xtrabackup/8.4/encrypt-backups.html));
  `mysqldump` and MySQL Shell dumps are piped or post-processed through a
  tool such as `age`, `gpg` or `openssl`. Binary logs on disk can be
  encrypted by the server with `binlog_encryption`
  ([Encrypting Binary Log Files and Relay Log Files](https://dev.mysql.com/doc/refman/8.4/en/replication-binlog-encryption.html)).

A compress-then-encrypt pipeline, and the proof that it decrypts back to
the same bytes. `openssl enc` gives confidentiality but no integrity
protection, so keep a checksum of the plaintext and verify it after
decryption. In the lab the key sits next to the backup; in production it
must not:

```bash test
./lab shell primary <<'SH'
set -euo pipefail
cd /backups/m06
openssl rand -base64 32 > backup.key && chmod 600 backup.key
sha256sum < shop.sql > shop.sql.sha256
zstd -q -c shop.sql \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass file:backup.key -out shop.sql.zst.enc
ls -lh shop.sql shop.sql.zst.enc | awk '{print $5, $9}'
restored="$(openssl enc -d -aes-256-cbc -pbkdf2 -pass file:backup.key \
              -in shop.sql.zst.enc | zstd -q -d | sha256sum)"
[ "$restored" = "$(cat shop.sql.sha256)" ] && echo "decrypted copy matches"
SH
```

```text
39M shop.sql
9.5M shop.sql.zst.enc
decrypted copy matches
```

Clean up this section's files:

```bash test
./lab shell primary <<'SH'
rm -rf /backups/m06
SH
```

## Common mistakes and troubleshooting

- **No restore test.** The backup job exits 0 every night and the file is
  empty, truncated, or missing a schema. Only a restore finds that out.
- **Binary log retention shorter than the backup interval**, or binlogs
  only on the database host. Point-in-time recovery then has a gap, or no
  source at all.
- **Restoring an `ON`/`AUTO` dump into a replicated primary.** The load
  runs with `sql_log_bin=0`, the primary changes, the replicas do not, and
  the next write to an affected row breaks replication with 1032 or 1062.
  On a server that already has those GTIDs it fails at `GTID_PURGED` first.
- **Replaying binlogs without thinking about GTIDs.** On a server that has
  executed them, the replay silently does nothing.
- **Trusting `--single-transaction` with MyISAM tables**, or running DDL
  during the dump.
- **Taking FTWRL on a busy server.** A long query in front of it turns a
  one-second lock into an outage; `--source-data` and MySQL Shell's
  `consistent` mode both take it briefly. Watch for it in the processlist
  as `Waiting for global read lock`.
- **`mysqlbinlog ... | mysql` with several separate pipes** for several
  files: a temporary table or user variable created in one file is gone in
  the next. Replay all files in one `mysqlbinlog` invocation.
- **Encrypted backup, key on the same host.** That is obfuscation.

## Further reading

- [Backup and Recovery](https://dev.mysql.com/doc/refman/8.4/en/backup-and-recovery.html) (MySQL 8.4 manual, chapter 9)
- [Establishing a Backup Policy](https://dev.mysql.com/doc/refman/8.4/en/backup-policy.html)
- [mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html) and [mysqlbinlog](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html)
- [MySQL Shell dump](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-dump-instance-schema.html) and [load](https://dev.mysql.com/doc/mysql-shell/26.7/en/mysql-shell-utilities-load-dump.html) utilities
- [The Clone Plugin](https://dev.mysql.com/doc/refman/8.4/en/clone-plugin.html)
- [Percona XtraBackup 8.4 documentation](https://docs.percona.com/percona-xtrabackup/8.4/)
- [Point-in-Time (Incremental) Recovery](https://dev.mysql.com/doc/refman/8.4/en/point-in-time-recovery.html)

## Next

Do the [exercise](exercise.md): an accidental `DELETE` in the middle of a
busy morning, and a point-in-time recovery that keeps everything else.
Then check yourself with the [quiz](quiz.md).

Module 7, [Replication and high availability](../07-replication-ha/README.md),
looks at the binary log from the other side: as the stream that keeps
replicas in step.
