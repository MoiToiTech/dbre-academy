# Exercise — Architecture tour

`time: ~25 min` · `scenario: 01-architecture-tour`

The lesson showed you the parts of the server. Here you trace three real
things through them, the way you would during an incident:

- a **connection** to the operating system thread that serves it;
- a **committed write** to the binary log file that holds it;
- a **table** to its pages in the buffer pool and its file on disk.

Then you fix a storage mistake someone made on this server.

## Set up

```bash test
./lab scenario setup 01-architecture-tour
```

Setup creates a `lab` schema with two tables and starts a long-running
connection:

- `lab.answers` — four questions; you write the answers into it.
- `lab.audit_log` — 501 rows, created by a colleague with
  `TABLESPACE innodb_system`.
- A connection as `app` running `SELECT SLEEP(86400) AS nightly_report`,
  standing in for a stuck reporting job.

```sql
SELECT question, asks FROM lab.answers;
```

```text
+----------------------+-----------------------------------------------------------------------------+
| question             | asks                                                                        |
+----------------------+-----------------------------------------------------------------------------+
| audit_binlog_file    | Binary log file that holds the setup marker row inserted into lab.audit_log |
| audit_log_old_file   | File that held lab.audit_log before you moved it                            |
| orders_primary_pages | Pages of the PRIMARY index of shop.orders now in the buffer pool            |
| sleeper_os_thread    | OS thread id (LWP) serving the connection running nightly_report            |
+----------------------+-----------------------------------------------------------------------------+
```

Record each answer with an `UPDATE`, for example:

```sql
UPDATE lab.answers SET answer = '12345' WHERE question = 'sleeper_os_thread';
```

You may check as often as you like; the check tells you which answers are
right:

```bash test expect-error
./lab scenario check 01-architecture-tour
```

## Task 1 — Which OS thread serves the stuck connection?

Find the `nightly_report` connection and the Linux thread id that runs it.
Record it as `sleeper_os_thread`. Then confirm it from the operating system
side: inside the container, the thread appears in `ps -L -p 1` with that
LWP.

<details>
<summary>Hint</summary>

`SHOW PROCESSLIST` gives you the connection id. `performance_schema.threads`
maps `PROCESSLIST_ID` to `THREAD_OS_ID`. For the OS side, use
`./lab exec primary ps -L -o pid,lwp,comm -p 1`.

</details>

## Task 2 — Which binary log file holds the marker row?

Setup inserted one row into `lab.audit_log` with the event text
`setup marker: price list approved`. It rotated the binary log before and
after that insert, so the file you want is neither the first nor the
current one. Find it and record its name (for example `binlog.000005`) as
`audit_binlog_file`. If you run the setup more than once, there will be
several marker rows; the newest one counts.

<details>
<summary>Hint</summary>

`SHOW BINARY LOGS` lists the files. `SHOW BINLOG EVENTS IN 'binlog.0000NN'`
shows a `Table_map` event naming `lab.audit_log`. To see the row values
themselves, decode the file with `mysqlbinlog`:

```bash
./lab exec primary mysqlbinlog -v --base64-output=DECODE-ROWS \
  /var/lib/mysql/binlog.0000NN | grep -B2 -A3 'setup marker'
```

```text
###   @1=512
###   @2='2026-01-02 09:00:00'
###   @3='setup marker: price list approved'
# at 500
#261013 10:44:44 server id 1  end_log_pos 531 CRC32 0x9f7c35ab 	Xid = 340
```

</details>

## Task 3 — How much of shop.orders is cached?

Read the whole clustered index of `shop.orders` once (any query that has to
visit every row will do, for example `SELECT SUM(total_cents) FROM
shop.orders`). Then count how many pages of its `PRIMARY` index are in the
buffer pool and record the number as `orders_primary_pages`. The check
recomputes it live and accepts your answer within 5%.

Compare your number with the size of the index in
`mysql.innodb_index_stats` (`stat_name = 'size'`, in pages). Is the whole
index cached?

<details>
<summary>Hint</summary>

`information_schema.INNODB_BUFFER_PAGE` has one row per page in the pool.
Its `TABLE_NAME` is quoted: `` '`shop`.`orders`' ``. Filter on
`INDEX_NAME = 'PRIMARY'` as well.

</details>

## Task 4 — Get lab.audit_log out of ibdata1

First find out which file `lab.audit_log` lives in, and record it as
`audit_log_old_file`. Then move the table into its own file-per-table
tablespace without losing rows, so that the space it uses can be returned to
the operating system later. Afterwards, find the new `.ibd` file in the data
directory.

<details>
<summary>Hint</summary>

`information_schema.INNODB_TABLES` gives each table's `SPACE` id;
`information_schema.FILES` maps a `FILE_ID` to a `FILE_NAME`. Space id 0 is
special. To move the table, see `ALTER TABLE ... TABLESPACE` in
[General Tablespaces](https://dev.mysql.com/doc/refman/8.4/en/general-tablespaces.html).

</details>

## Check

```text
$ ./lab scenario check 01-architecture-tour
Checking 01-architecture-tour
  PASS sleeper_os_thread = 142
  PASS audit_binlog_file = binlog.000020
  PASS orders_primary_pages = 601 (now 601)
  PASS audit_log_old_file = ./ibdata1
  PASS lab.audit_log lives in its own tablespace
  PASS lab.audit_log still has all 501 rows
All checks passed.
```

Your thread id, file name and page count will differ.

A reference solution is in `labs/scenarios/01-architecture-tour/solve.sh`.
Try the tasks first.

## Think about it

- The `nightly_report` connection holds no locks and does no I/O. What does
  it still cost the server? (Think thread, memory, `max_connections`.)
- `ALTER TABLE ... TABLESPACE innodb_file_per_table` rebuilt the table. What
  did that write to the redo log, to the binary log and to the replica?
- `ibdata1` did not shrink after the move. What would it take to get that
  space back?

## Clean up

```bash test
./lab scenario reset 01-architecture-tour
```

Reset stops the `nightly_report` connection and drops the `lab` schema.
