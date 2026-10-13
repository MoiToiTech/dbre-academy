# Module 9 — Incident response and troubleshooting

`time: ~90 min` · `lab: ./lab scenario setup 09-too-many-connections, 09-wont-start` · `level: fundamentals`

When the database is down, nobody cares how elegant your schema is. What
matters is how fast you see what is wrong, whether your first action makes
things better or worse, and whether you can explain afterwards what happened.
This module is about the first hour of a MySQL incident: who does what, what
to look at in the first five minutes, which mitigations are safe, and how to
read what mysqld tells you when it will not start, crashes, or refuses
connections.

## Learning objectives

By the end of this module you can:

- run an incident through its stages — detect, triage, mitigate, resolve,
  review — and say why mitigation comes before root cause;
- check a MySQL host in five minutes: process, connectivity, error log,
  sessions, InnoDB transactions, replication, host resources;
- choose between `KILL QUERY`, `KILL`, stopping a client and restarting
  mysqld, and know which "fixes" are dangerous;
- get into a server that answers `ERROR 1040: Too many connections`, and know
  why the administrative interface is the better way in;
- recover a server that fails to start because of a persisted setting;
- read InnoDB crash recovery in the error log, and recognise disk-full and
  runaway-transaction incidents.

## Prerequisites

- Modules [01-architecture](../01-architecture/),
  [02-install-config-access](../02-install-config-access/) (persisted
  settings, accounts), [03-innodb-transactions-locking](../03-innodb-transactions-locking/),
  [05-performance-diagnostics](../05-performance-diagnostics/) and
  [07-replication-ha](../07-replication-ha/).
- The lab running: `./lab up`. Run every command from the `labs/` directory.

Several commands below use `docker compose` directly. From `labs/` it picks up
the lab's project name from `docker-compose.yml`, so they work for the default
lab and for a lab started with `DBRE_PROJECT`.

## How an incident runs

An incident is any unplanned event that hurts, or is about to hurt, users or
data. It moves through five stages:

1. **Detect.** An alert fires, a customer complains, a colleague notices. The
   clock starts at the first symptom, not when someone opens a terminal.
2. **Triage.** How bad is it, how many users, is it getting worse? Declare the
   incident and its severity early; downgrading later is cheap.
3. **Mitigate.** Stop the bleeding. Roll back the release, kill the blocking
   session, move the reports off the broken replica. Mitigation does not need
   the root cause — it needs a safe action that reduces impact.
4. **Resolve.** Remove the cause so the problem does not come back the moment
   you look away: fix the config, add the index, repair the data.
5. **Review.** Write a blameless post-incident review and track its action
   items ([template](../../../docs/templates/postmortem.md)).

Mitigate before root-causing. While you read source code to understand *why*
checkout deadlocks, checkout is still down. The Google SRE book calls this out
directly: the priority during an incident is to stop the impact, and the
investigation can wait for the review
([Managing Incidents](https://sre.google/sre-book/managing-incidents/)).

### Roles

On anything larger than a one-person fix, split the work so that nobody is
typing commands and writing status updates at the same time:

| Role | Does | Does not |
|---|---|---|
| Incident commander (IC) | Owns the incident, assigns work, decides | Type commands |
| Operations lead | Investigates and changes systems | Talk to customers |
| Communications | Posts updates on a fixed cadence | Guess at causes |
| Scribe (often the IC) | Keeps the timeline with UTC times | Edit history later |

These are the roles from the
[SRE book](https://sre.google/sre-book/managing-incidents/) and the
[SRE workbook](https://sre.google/workbook/incident-response/), trimmed for a
small team. On a two-person team one person is IC plus communications, the
other is operations. The point is that someone is explicitly in charge.

### Severity and communication

Define severities before you need them. An example scale:

| Severity | Meaning | Update cadence |
|---|---|---|
| SEV1 | Core function down or data at risk | Every 15–30 min |
| SEV2 | Degraded for many users, workaround exists | Every hour |
| SEV3 | Minor, contained, no data risk | At start and end |

Every update answers the same four questions: what is the impact now, what we
know, what we are doing, when the next update is. "No change, next update at
14:30" is a valid update; silence is not.

<!-- founder-review: a real example of an incident update that worked (or one
that made things worse by guessing at a cause) would help here -->

The first thing to run in this lab during any incident is the lab's own
summary — the equivalent of your dashboard's front page:

```bash test
./lab status
```

## The first five minutes on a MySQL host

The same questions, in the same order, every time. Write down what you see,
with the time; it becomes the incident timeline.

**1. Is mysqld running?** From the outside (the container), then the process
itself. `procps` is installed in the lab image for this.

```bash test
docker compose ps primary --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
./lab exec primary ps -o pid,etime,pcpu,rss,args -C mysqld
```

```text
SERVICE   STATE     STATUS
primary   running   Up 8 minutes (healthy)
    PID     ELAPSED %CPU   RSS COMMAND
      1       08:12 80.1 582680 mysqld
```

`ps` `%CPU` is an average over the process's whole life, not the current
load; use `top -b -n 1` for "now". A short `ELAPSED` you did not expect means
mysqld restarted — find out why before anything else.

**2. Can I connect, and what does the error log say?** In this lab mysqld logs
to stderr, so the error log is the container log (`./lab logs primary` follows
it; below, without following).

```bash test
./lab sql -e "SELECT NOW(), @@hostname, VERSION()"
docker compose logs --no-log-prefix --tail 500 primary \
  | grep -E '\[(ERROR|Warning)\]' | tail -n 5 || true
```

**3. How busy is it?** `Threads_connected` is how many sessions exist;
`Threads_running` is how many are doing something right now (your own query
included). A healthy OLTP server has a handful running; dozens running on a
few cores means queueing.
[Server status variables](https://dev.mysql.com/doc/refman/8.4/en/server-status-variables.html).

```sql test
SHOW GLOBAL STATUS WHERE Variable_name IN
  ('Uptime', 'Threads_connected', 'Threads_running', 'Max_used_connections',
   'Connection_errors_max_connections', 'Aborted_connects');
```

```text
+-----------------------------------+-------+
| Variable_name                     | Value |
+-----------------------------------+-------+
| Aborted_connects                  | 3     |
| Connection_errors_max_connections | 0     |
| Max_used_connections              | 11    |
| Threads_connected                 | 2     |
| Threads_running                   | 3     |
| Uptime                            | 492   |
+-----------------------------------+-------+
```

Counters are cumulative since start-up. One sample tells you little; take two
a few seconds apart and compare.

**4. Who is connected, and what are they doing?** Group, don't scroll: a list
of 400 sessions hides the one pattern that matters. In MySQL 8.4 use
`performance_schema.processlist`;
`INFORMATION_SCHEMA.PROCESSLIST` is deprecated
([processlist table](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-processlist-table.html)).

```sql test
SELECT USER, SUBSTRING_INDEX(HOST, ':', 1) AS client, COMMAND, STATE,
       COUNT(*) AS n, MAX(TIME) AS max_s
FROM performance_schema.processlist
WHERE COMMAND <> 'Daemon'
GROUP BY USER, client, COMMAND, STATE
ORDER BY n DESC;
```

**5. Is InnoDB stuck on something?** Long transactions, lock waits and the
history list length. `sys.innodb_lock_waits` names the blocker and even prints
the `KILL` statement — read it, don't paste it blindly
([sys.innodb_lock_waits](https://dev.mysql.com/doc/refman/8.4/en/sys-innodb-lock-waits.html)).

```sql test
SELECT trx_id, trx_state, trx_started, trx_rows_locked, trx_rows_modified,
       trx_mysql_thread_id
FROM information_schema.innodb_trx
ORDER BY trx_started
LIMIT 5;

SELECT wait_age_secs, locked_table, waiting_pid, blocking_pid,
       sql_kill_blocking_connection
FROM sys.innodb_lock_waits;
```

`SHOW ENGINE INNODB STATUS` has the same and more (history list length in
the TRANSACTIONS section, the latest deadlock); module 03 covers reading it.

**6. Is replication healthy?** On the replica. Running threads and zero lag
are not the same as correct data, but they are the first check.

```sql test replica
SELECT c.SERVICE_STATE AS io, a.SERVICE_STATE AS applier,
       c.LAST_ERROR_NUMBER AS io_err, w.LAST_ERROR_NUMBER AS sql_err,
       w.LAST_ERROR_MESSAGE
FROM performance_schema.replication_connection_status c
JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)
JOIN performance_schema.replication_applier_status_by_worker w USING (CHANNEL_NAME)
ORDER BY w.LAST_ERROR_NUMBER DESC
LIMIT 1;
```

**7. Is the host the problem?** Memory, disk, load. One caveat for
containers: `free` and `uptime` read the kernel's numbers — on Docker Desktop
that is the Linux VM, not a per-container limit.

```bash test
./lab exec primary sh -c \
  'free -m; echo; df -h /var/lib/mysql; echo; top -b -n 1 | head -n 12'
```

```text
               total        used        free      shared  buff/cache   available
Mem:           16028        7804        7271          24        1228        8223
Swap:          17052           0       17052

Filesystem      Size  Used Avail Use% Mounted on
/dev/vdb1       1.2T   56G  1.1T   5% /var/lib/mysql
...
```

Your numbers will differ. What matters is the habit: process, connect, log,
load, sessions, InnoDB, replication, host — then decide.

## Safe and dangerous mitigations

Rank every action by blast radius and by whether you can undo it.

| Action | Blast radius | Undo? |
|---|---|---|
| `KILL QUERY <id>` | One statement | The client can retry |
| `KILL <id>` | One session; its transaction rolls back | Client reconnects |
| Stop or roll back the client | One application | Redeploy |
| `SET GLOBAL` a dynamic limit | Whole server | `SET GLOBAL` back |
| Restart mysqld | Every session; cold buffer pool | No |
| Fail over | Every client; data loss if unclear | Hard |

Things that look like fixes and are not, unless you know exactly why you are
doing them:

- **Restarting mysqld** to clear a "stuck" server. It drops every
  connection, empties the buffer pool (slow for minutes or hours afterwards),
  and a long transaction you killed by restarting still has to roll back —
  during crash recovery, now with the whole server waiting. It also destroys
  evidence: the processlist and lock state you needed for the review are gone.
- **`RESET REPLICA ALL`** to "clear" a replication error. It deletes the
  replica's connection metadata; it does not fix the data that broke
  replication ([RESET REPLICA](https://dev.mysql.com/doc/refman/8.4/en/reset-replica.html)).
- **Skipping the failing transaction** to make the error go away. The replica
  keeps running with different data from the source; the manual asks you to
  check whether the transaction needs applying first
  ([skipping transactions](https://dev.mysql.com/doc/refman/8.4/en/replication-administration-skip.html)).
- **`--skip-grant-tables`** to get in. It disables authentication for
  everyone; mysqld also enables `skip_networking` so that only local
  connections work, but every local user is now root
  ([server options](https://dev.mysql.com/doc/refman/8.4/en/server-options.html#option_mysqld_skip-grant-tables)).
  There is almost always a better way in (next section).
- **Failing over while the state is unclear.** If you do not know whether the
  primary is down or merely slow, promoting a replica can leave two writable
  servers. Fail over on evidence, not on a hunch.

### Long-running query, runaway transaction

`KILL QUERY` stops the statement and keeps the connection; `KILL` (that is,
`KILL CONNECTION`) ends both. The kill flag is checked at intervals, so a
statement may take a moment to die
([KILL](https://dev.mysql.com/doc/refman/8.4/en/kill.html)). Start an
expensive ad-hoc report, find it, and stop only the query:

```bash test
docker compose exec -d primary sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -c -uroot -e "
  SELECT /* report:adhoc */ COUNT(*)
  FROM shop.order_items a JOIN shop.order_items b USING (product_id)"'
sleep 3
./lab sql --table -e "
  SELECT ID, USER, COMMAND, TIME, REPLACE(LEFT(INFO, 34), '\n', ' ') AS info
  FROM performance_schema.processlist
  WHERE INFO LIKE '%report:adhoc%' AND ID <> CONNECTION_ID()"
id="$(./lab sql -N -e "SELECT ID FROM performance_schema.processlist
                      WHERE INFO LIKE '%report:adhoc%' AND ID <> CONNECTION_ID()")"
./lab sql -e "KILL QUERY $id"
```

```text
+----+------+---------+------+------------------------------------+
| ID | USER | COMMAND | TIME | info                               |
+----+------+---------+------+------------------------------------+
| 23 | root | Query   |    3 | SELECT /* report:adhoc */ COUNT(*) |
+----+------+---------+------+------------------------------------+
```

For read-only `SELECT` statements, `max_execution_time` (or the
`MAX_EXECUTION_TIME` optimizer hint) makes the server do this for you
([max_execution_time](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html#sysvar_max_execution_time)).

A write is different. Killing a large `INSERT`, `UPDATE` or `DELETE` makes
InnoDB undo every row it changed, and undo is often slower than the work
itself. Watch it happen:

```bash test
./lab sql -e "CREATE DATABASE IF NOT EXISTS lab;
  CREATE TABLE lab.crash_demo LIKE shop.order_items;"
docker compose exec -d primary sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -e "
  INSERT INTO lab.crash_demo
  SELECT i.order_id + 1000000, i.line_no + 10 * x.n, i.product_id, i.quantity,
         i.price_cents
  FROM shop.order_items i,
       (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) x"'
until [ "$(./lab sql -N -e "SELECT IFNULL(MAX(trx_rows_modified), 0)
                            FROM information_schema.innodb_trx")" -gt 1000000 ]; do
  sleep 0.5
done
./lab sql -e "KILL $(./lab sql -N -e 'SELECT trx_mysql_thread_id
                                     FROM information_schema.innodb_trx')"
for i in 1 2 3; do
  ./lab sql -N -e "SELECT CONCAT_WS(' ', CURTIME(), trx_state, trx_rows_modified)
                   FROM information_schema.innodb_trx"
  sleep 0.5
done
until [ "$(./lab sql -N -e 'SELECT COUNT(*) FROM information_schema.innodb_trx')" = 0 ]; do
  sleep 0.5
done
./lab sql -e "DROP DATABASE lab"
```

```text
11:01:48 ROLLING BACK 1154712
11:01:48 ROLLING BACK 839546
11:01:49 ROLLING BACK 581091
```

`trx_rows_modified` counts down as the rollback proceeds. In the lab it takes
a couple of seconds. The manual's rule of thumb for an interrupted transaction
is that rolling it back can take three or four times as long as it had been
running ([InnoDB crash recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)).
Restarting does not skip it: the rollback resumes after crash recovery (next
sections), and its locks are held until it finishes. Before
killing a big write, check `trx_rows_modified` and decide whether letting it
finish is cheaper.

<!-- founder-review: a first-hand story of a killed batch job whose rollback
outlasted the original run would land this point -->

## Reading the error log

The error log is where mysqld explains itself: why it stopped, what crash
recovery did, which settings it rejected. Each line has the same shape
([the error log](https://dev.mysql.com/doc/refman/8.4/en/error-log.html)):

```text
2026-10-13T10:32:29.770756Z 1 [ERROR] [MY-011087] [Server] Different lower_case_table_names ...
└ time (UTC)                └ thread └ priority └ error code └ subsystem └ message
```

The lab runs with `log_error_verbosity = 3`, so notes are included. While the
server is up, recent events are also queryable over SQL — useful on managed
MySQL where you have no shell:

```sql test
SELECT @@log_error, @@log_error_verbosity;

SELECT LOGGED, PRIO, ERROR_CODE, SUBSYSTEM, LEFT(DATA, 50) AS data
FROM performance_schema.error_log
WHERE PRIO IN ('Error', 'Warning')
ORDER BY LOGGED DESC
LIMIT 3;
```

```text
+-----------------+-----------------------+
| @@log_error     | @@log_error_verbosity |
+-----------------+-----------------------+
| stderr          |                     3 |
+-----------------+-----------------------+
+----------------------------+---------+------------+-----------+--------------------------------------------------+
| LOGGED                     | PRIO    | ERROR_CODE | SUBSYSTEM | data                                             |
+----------------------------+---------+------------+-----------+--------------------------------------------------+
| 2026-10-13 11:01:14.067553 | Warning | MY-011810  | Server    | Insecure configuration for --pid-file: Location  |
| 2026-10-13 11:01:14.065172 | Warning | MY-010068  | Server    | CA certificate ca.pem is self signed.            |
| 2026-10-13 11:01:12.539871 | Warning | MY-011070  | Server    | 'binlog_format' is deprecated and will be remove |
+----------------------------+---------+------------+-----------+--------------------------------------------------+
```

The catch: `performance_schema.error_log` only holds the current run when the
log goes to stderr (mysqld says so at start-up: *Error-log destination
"stderr" is not a file. Can not restore error log messages from previous
run.*). The reason the *previous* run died is in `docker logs`, or in the log
file on a server that writes one — and not in SQL.

Search for codes, not for words: `MY-011087` finds the same event in every
language and version of the message.

## Common availability failures

### "Too many connections"

`max_connections` caps client connections. When it is reached, new clients
get `ERROR 1040 (08004): Too many connections` and the
`Connection_errors_max_connections` counter goes up. In 8.4.11 nothing is
written to the error log, even at verbosity 3 — your alerting has to watch
the counter, or `Threads_connected / max_connections` (the lab's Prometheus
rule `MySQLConnectionsNearLimit` does the latter).

mysqld permits `max_connections + 1` connections: the extra one is reserved
for an account with `CONNECTION_ADMIN` (or the deprecated `SUPER`), so that an
administrator can get in and look
([Too many connections](https://dev.mysql.com/doc/refman/8.4/en/too-many-connections.html)).
Note the word *one*. Saturate the lab primary and try two root sessions:

```bash test
./lab scenario setup 09-too-many-connections
./lab sql --table -e "SELECT @@max_connections;
  SHOW GLOBAL STATUS WHERE Variable_name IN
    ('Threads_connected', 'Max_used_connections', 'Connection_errors_max_connections');"
./lab exec primary sh -c \
  'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -e "DO SLEEP(5)"' &
sleep 2
./lab sql -e "SELECT 'second root session'" || echo "refused: the reserved slot is taken"
wait
```

```text
The application cannot connect:
  ERROR 1040 (08004): Too many connections
+-------------------+
| @@max_connections |
+-------------------+
|                30 |
+-------------------+
+-----------------------------------+-------+
| Variable_name                     | Value |
+-----------------------------------+-------+
| Connection_errors_max_connections | 13    |
| Max_used_connections              | 31    |
| Threads_connected                 | 31    |
+-----------------------------------+-------+
ERROR 1040 (HY000): Too many connections
refused: the reserved slot is taken
```

The second root session is refused. In a real incident the reserved slot is
gone as soon as a monitoring agent with too many privileges, a colleague, or
your own forgotten terminal takes it. Even a shell pipeline like
`./lab sql -N -e "...generate KILLs..." | ./lab sql` needs two sessions at
once and fails; run the steps one after another.

**The better way in: the administrative interface.** Set `admin_address`, and
mysqld listens on a second port (`admin_port`, default 33062) for accounts with
`SERVICE_CONNECTION_ADMIN`. Connections there are not limited by
`max_connections` at all
([administrative connection interface](https://dev.mysql.com/doc/refman/8.4/en/administrative-connection-interface.html)).
`admin_address` is read-only and — unlike most settings — cannot be persisted:
`SET PERSIST_ONLY admin_address = '127.0.0.1'` fails in 8.4.11 with
`ERROR 1238 ... is a non persistent read only variable`. It has to go into an
option file and needs a restart. The lab's `mysql/primary.cnf` does not set it,
so the demo drops a file into the container's `conf.d` (it lasts until the
container is recreated):

```bash test
./lab exec primary sh -c \
  'printf "[mysqld]\nadmin_address = 127.0.0.1\n" > /etc/mysql/conf.d/admin.cnf'
docker compose stop -t 120 primary
./lab up > /dev/null
until [ "$(./lab sql -N -e "SELECT COUNT(*) FROM performance_schema.processlist
                             WHERE USER = 'app'")" -ge 29 ]; do sleep 1; done
for i in 1 2 3; do
  ./lab exec primary sh -c \
    'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -h127.0.0.1 -P33062 -e "DO SLEEP(5)"' &
done
sleep 2
./lab exec primary sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD \
  mysql -uroot -h127.0.0.1 -P33062 --table -e "
    SELECT USER, SUBSTRING_INDEX(HOST, \":\", 1) AS client, COMMAND, COUNT(*) AS n
    FROM performance_schema.processlist
    GROUP BY USER, client, COMMAND ORDER BY n DESC"'
wait
```

```text
+-----------------+---------------+------------------+----+
| USER            | client        | COMMAND          | n  |
+-----------------+---------------+------------------+----+
| app             | 192.168.156.4 | Sleep            | 29 |
| root            | 127.0.0.1     | Query            |  4 |
| event_scheduler | localhost     | Daemon           |  1 |
| repl            | 192.168.156.2 | Binlog Dump GTID |  1 |
+-----------------+---------------+------------------+----+
```

29 application connections plus the replica's dump thread fill all 30 slots,
and four root sessions still got in through port 33062. The error log
confirms the interface at start-up: `[MY-013292] [Server] Admin interface
ready for connections, address: '127.0.0.1'  port: 33062`. In production, bind
it to a management network or to localhost, and grant
`SERVICE_CONNECTION_ADMIN` only to people and tools that need it.

Notice also what the restart did *not* do: the limit is still 30, because the
scenario used `SET PERSIST`, and the application refilled every slot within
seconds. A restart is not a mitigation for a connection leak. Undo the demo:

```bash test
./lab exec primary rm /etc/mysql/conf.d/admin.cnf
./lab scenario reset 09-too-many-connections
docker compose stop -t 120 primary
./lab up > /dev/null
./lab sql -N -e "SELECT IFNULL(@@admin_address, 'no admin interface'), @@max_connections"
```

The order of work for a saturated server is in the exercise: get in, find the
source, stop the source, then restore the limit. Raising `max_connections`
buys time (every connection costs memory, so not unlimited time); it does not
explain anything.

### mysqld will not start

A server that will not start is usually telling you why, in the last
`[ERROR]` lines before `Aborting`. Common causes: a typo or an unknown option
in an option file, a bad value persisted with `SET PERSIST_ONLY`, a data
directory owned by the wrong user, a port already in use, a full disk.

Persisted settings deserve attention because they live in `mysqld-auto.cnf`
in the data directory, not with the rest of the configuration, and they are
applied *after* all option files
([persisted system variables](https://dev.mysql.com/doc/refman/8.4/en/persisted-system-variables.html)).
Someone persists a setting today; it bites at the next restart, weeks later,
during an unrelated maintenance window. For example, `lower_case_table_names`
can only be set when the data directory is initialised
([identifier case sensitivity](https://dev.mysql.com/doc/refman/8.4/en/identifier-case-sensitivity.html)).
Persist it on a running server and the next start fails like this (8.4.11):

```text
[ERROR] [MY-011087] [Server] Different lower_case_table_names settings for server ('1') and data dictionary ('0').
[ERROR] [MY-010020] [Server] Data Dictionary initialization failed.
[ERROR] [MY-010119] [Server] Aborting
```

The manual lists the ways out: start the server with `persisted_globals_load`
disabled (it then ignores `mysqld-auto.cnf`) and remove the bad entry with
`RESET PERSIST`, or remove the file — losing every other persisted setting
with it. The exercise walks through the first. Two traps to avoid:

- **Do not start a rescue instance where clients can reach it.** A first
  attempt at this exercise used `docker compose run primary ...`, which gives
  the rescue container the network alias `primary`. The replica reconnected to
  the half-repaired rescue instance within seconds. Start the rescue
  instance with no network (`docker run --network none`) and connect through
  its socket.
- **Never run two mysqld processes on one data directory.** Stop the rescue
  instance cleanly before starting the real one.

While the primary is down, the replica keeps trying to reconnect — for
`SOURCE_RETRY_COUNT` attempts (default 10), `SOURCE_CONNECT_RETRY` seconds
apart (5 in this lab, 60 by default), and then its I/O thread stops
([CHANGE REPLICATION SOURCE TO](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html)).
After an outage longer than that, the primary comes back and the replica
stays disconnected until someone runs `START REPLICA`:

```text
Last_IO_Error: Error reconnecting to source 'repl@primary:3306'. This was attempt 10/10,
               with a delay of 5 seconds between attempts. Message: Unknown MySQL server
               host 'primary' (-2)
```

### Crash recovery after an abrupt stop

When mysqld stops without a clean shutdown — `kill -9`, the OOM killer, a
power cut, a container runtime that ran out of patience — InnoDB replays the
redo log at the next start and rolls back transactions that never committed
([InnoDB crash recovery](https://dev.mysql.com/doc/refman/8.4/en/innodb-recovery.html)).
Committed transactions survive (the lab runs `innodb_flush_log_at_trx_commit
= 1` and `sync_binlog = 1`); uncommitted ones disappear. Kill the primary in
the middle of a large uncommitted insert:

```bash test
./lab sql -e "CREATE DATABASE IF NOT EXISTS lab;
  CREATE TABLE lab.crash_demo LIKE shop.order_items;
  INSERT INTO lab.crash_demo VALUES (1, 1, 1, 1, 100);"
docker compose exec -d primary sh -c 'MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql -uroot -e "
  INSERT INTO lab.crash_demo
  SELECT i.order_id + 1000000, i.line_no + 10 * x.n, i.product_id, i.quantity,
         i.price_cents
  FROM shop.order_items i,
       (SELECT 1 AS n UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) x"'
until [ "$(./lab sql -N -e "SELECT IFNULL(MAX(trx_rows_modified), 0)
                            FROM information_schema.innodb_trx")" -gt 300000 ]; do
  sleep 0.5
done
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose kill -s KILL primary
./lab up > /dev/null
docker compose logs --no-log-prefix --since "$since" primary \
  | grep -E 'MY-01255[12]|MY-01253[25]|MY-01301[1-5]|MY-010931' | cut -c 1-120
./lab sql -e "SELECT COUNT(*) AS rows_after_recovery FROM lab.crash_demo; DROP DATABASE lab;"
```

```text
...Z 1 [Note] [MY-012551] [InnoDB] Database was not shutdown normally!
...Z 1 [Note] [MY-012552] [InnoDB] Starting crash recovery.
...Z 1 [Note] [MY-012532] [InnoDB] Applying a batch of 2651 redo log records ...
...Z 1 [Note] [MY-012535] [InnoDB] Apply batch completed!
...Z 0 [Note] [MY-013014] [InnoDB] Starting in background the rollback of uncommitted transactions
...Z 0 [Note] [MY-013011] [InnoDB] Rolling back trx with id 22315, 555604 rows to undo
...Z 0 [System] [MY-010931] [Server] /usr/sbin/mysqld: ready for connections. Version: '8.4.11' ...
...Z 0 [Note] [MY-013015] [InnoDB] Rollback of non-prepared transactions completed
rows_after_recovery
1
```

Read it in order: redo is applied first (the server is not available until
that finishes); then the server accepts connections *while* the uncommitted
transaction is still being rolled back in the background. Until it finishes,
new sessions can hit its locks — the manual warns about exactly that. The one
committed row survived; the half-done insert did not. The amount of redo to apply
depends on how far the last checkpoint was behind; the rollback depends on
how big the uncommitted transactions were.

A quieter variant needs no `kill` at all. `docker compose stop` and
`restart` send SIGTERM, wait 10 seconds by default, then send SIGKILL
([docker compose stop](https://docs.docker.com/reference/cli/docker/compose/stop/)).
With the replica's dump thread attached, mysqld here spends about 11
seconds just closing connections before InnoDB starts its own shutdown:

```text
...11:32:56Z 0 [Note] [MY-010067] [Server] Giving 2 client threads a chance to die gracefully
...11:33:07Z 0 [Note] [MY-013072] [InnoDB] Starting shutdown...
...11:33:07Z 0 [Note] [MY-012980] [InnoDB] Shutdown completed; log sequence number ...
...11:33:07Z 0 [System] [MY-010910] [Server] /usr/sbin/mysqld: Shutdown complete ...
```

With the default timeout, mysqld was killed in the middle of that, and the
next start began with *Database was not shutdown normally!* and crash
recovery: a planned restart that behaved like a crash. The lab's
`docker-compose.yml` therefore sets `stop_grace_period: 120s` on both MySQL
services
([stop_grace_period](https://docs.docker.com/reference/compose-file/services/#stop_grace_period)),
and the shutdown above is a clean one. This module still writes
`docker compose stop -t 120`: it states the intent, and it is what you type
against a compose file that does not set a grace period.

Container platforms have the same trap. Kubernetes waits
`terminationGracePeriodSeconds`, 30 seconds by default, before SIGKILL
([Pod termination](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#pod-termination)).
Size it for a database's shutdown (connections to close, dirty pages to
flush), not for a web server's.

### Disk full

Not simulated in this lab: the lab's volumes share the Docker host's disk, so
filling one safely and repeatably is not possible here. What to know:

- For binary log writes (and MyISAM), mysqld does not crash on a full disk: it
  checks for space every minute and writes a warning to the error log every
  ten minutes, while the writing session waits
  ([how MySQL handles a full disk](https://dev.mysql.com/doc/refman/8.4/en/full-disk.html)).
  To clients the server looks hung, not down. Writes stall, reads may work.
- Free space safely. Purge binary logs with `PURGE BINARY LOGS`, never `rm`,
  and check first that no replica still needs them. Do not delete
  `ibdata*`, `undo_*`, `#innodb_redo` files or `*.ibd` files to make room;
  that is data loss.
- Look at the usual growth: binary logs (`binlog_expire_logs_seconds`), the
  slow and general logs, temporary files in `tmpdir`, a large `ALTER TABLE`
  that rebuilds a table and briefly needs its size again.
- Alert on free space well before 100%: a full disk is predictable hours in
  advance.

<!-- founder-review: a disk-full story (which file grew, how it was found)
would make this concrete -->

## Common mistakes and troubleshooting

- **Root-causing before mitigating.** If you have a safe mitigation, apply it,
  then investigate.
- **Changing two things at once.** You will not know which one worked. Note
  each change with its time.
- **`KILL` without looking.** The blocking session may be a migration halfway
  through a rebuild, or a payment batch. Check `trx_rows_modified` and ask the
  owner when you can.
- **Raising `max_connections` as the fix.** It moves the cliff; it does not
  find the leak. Each connection costs memory.
- **Restarting to "clear" a problem.** You lose the evidence and the warm
  buffer pool, and a large rollback continues after the restart anyway.
- **Trusting `SET GLOBAL` to last.** It is gone at the next restart; `SET
  PERSIST` is not, and that cuts both ways — check
  `performance_schema.persisted_variables` during any start-up failure.
- **`./lab check` says the lab is not running.** In `09-wont-start` that is
  the point: `./lab` refuses scenario commands while the primary is down. Use
  `./lab logs primary` and the exercise's steps.

## Further reading

- [Managing Incidents](https://sre.google/sre-book/managing-incidents/) and
  [Emergency Response](https://sre.google/sre-book/emergency-response/),
  Google SRE book.
- [Incident Response](https://sre.google/workbook/incident-response/), Google
  SRE workbook.
- [Problems and common errors](https://dev.mysql.com/doc/refman/8.4/en/problems.html)
  and [What to do if MySQL keeps crashing](https://dev.mysql.com/doc/refman/8.4/en/crashing.html),
  MySQL 8.4 Reference Manual.
- [Connection interfaces](https://dev.mysql.com/doc/refman/8.4/en/connection-interfaces.html),
  MySQL 8.4 Reference Manual.

## Next

Do the [exercise](exercise.md): a saturated server and a server that will not
start, both from scratch. Then check yourself with the [quiz](quiz.md), and
move on to the [final challenge](../10-final-challenge/), where three faults
arrive at once.
