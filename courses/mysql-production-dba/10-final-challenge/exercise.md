# Module 10 — The challenge

`time: ~60 min incident + ~60 min review` · `scenario: 10-final-incident`

Read the [brief](README.md) first. Then start a text file for your incident
log and note the time.

## 1. Start the incident

From `labs/`:

```bash test
./lab scenario setup 10-final-incident
```

The scenario starts two containers next to the database — the shop
application and the back-office console — and leaves three faults behind.
The check fails, fault by fault:

```bash test expect-error
./lab check 10-final-incident
```

```text
Checking 10-final-incident
Checkout (P1)
  PASS the shop application is still running
  FAIL something is still holding the row locks checkout needs
  FAIL a checkout-style update on shop.inventory completes within 5 seconds
API latency (P2)
  FAIL the pending-orders API query no longer reads the whole table (EXPLAIN rows: 199800)
Reports replica (stale data)
  FAIL replication threads on the replica (IO/SQL) (got 'ON/OFF', expected 'ON/ON')
  FAIL shop.payments differs between the primary and the replica
  PASS no new errant transactions on the replica
Stuck? HINT_LEVEL=1 ./lab check 10-final-incident
5 check(s) failed.
```

The first line, and the last of the replica section, pass now and must still
pass when you finish: they catch mitigations that cause a new problem.

## 2. Work the incident

There is no prescribed order — choosing one is part of the exercise. Some
questions to guide you, not a checklist to follow blindly:

**Triage (first 5–10 minutes).**

- Which symptom hurts users most right now? Which one risks money or data?
  Which can wait ten minutes?
- Are the three related? Look before you assume either way.
- Run the "first five minutes" from module 9. Where is the application's own
  log? (`docker logs <project>-shop-app`)
- Declare a severity and write your first status update in your log.

**Checkout.**

- What exactly does the application report? What is the waiting statement
  waiting *for*?
- Who holds what checkout needs, since when, and what is that session doing
  now? What did it run?
- What is the least disruptive action that releases checkout — and who would
  you ask before taking it, if you could?

**API latency.**

- Which statement does the new endpoint run, how often, and what does each
  call cost? Compare rows examined with rows returned.
- Why did the slow query log (`long_query_time = 1`) not show it?
- What index serves both the filter and the sort? Can you add it without
  blocking the table that checkout and the API both use?

**Stale reports.**

- Is the replica applying changes? If not, which transaction failed, and why?
- What does that transaction change, and what does the replica have for that
  row? What does the primary have?
- Which repair leaves the replica *correct*, not only running? What would
  skipping the transaction leave behind?
- If you write on the replica, how do you make sure the repair does not get a
  GTID of its own?

**Verify, and close.**

- `./lab check 10-final-incident` passes.
- The application log shows checkout succeeding and the API faster.
- Write the "resolved" update in your log, with the time.

## Hints

The check gives progressive hints. Ask for the next level only when you are
stuck, and note in your log that you did — it is honest material for the
review.

```bash
HINT_LEVEL=1 ./lab check 10-final-incident    # where to look
HINT_LEVEL=2 ./lab check 10-final-incident    # which tool or table
HINT_LEVEL=3 ./lab check 10-final-incident    # close to the answer
```

If you get into a state you cannot recover from, start over:
`./lab scenario reset 10-final-incident`, then set it up again.

## 3. Write the review

Copy [docs/templates/postmortem.md](../../../docs/templates/postmortem.md)
and fill it in from your incident log. Treat the three faults as one
incident with three contributing faults, or as three incidents — either is
defensible; say which and why. Then score yourself with the
[rubric](rubric.md).

## 4. Reset

```bash
./lab scenario reset 10-final-incident
```

---

<details>
<summary>Walkthrough — open only when you are done</summary>

One way through it, with the output from a fresh lab. Your thread ids, IP
addresses, GTIDs and timings will differ. The order here — checkout first,
then the replica, then the API — follows impact: checkout is failing outright
and losing orders; the reports are wrong, and finance closes at 17:00; the
dashboard is slow but works. A different order with a stated reason is fine.

### Triage

The application log tells you more than the pager:

```bash test
sleep 25   # in the lab, give the first checkouts time to time out
docker logs --tail 40 "${DBRE_PROJECT:-dbre}-shop-app" 2>&1 \
  | grep -E 'checkout|api-[12] ' | tail -n 5
```

```text
11:21:20 api-2 GET /v2/orders?status=pending 570 requests in 10s, avg 17773us
11:21:20 api-1 GET /v2/orders?status=pending 570 requests in 10s, avg 17756us
11:21:27 checkout-2 POST /checkout sku=31 500 20037ms 1205 (HY000) at line 2: Lock wait timeout exceeded; try restarting transaction
11:21:30 api-2 GET /v2/orders?status=pending 540 requests in 10s, avg 18701us
11:21:30 api-1 GET /v2/orders?status=pending 540 requests in 10s, avg 18700us
```

Every checkout waits the full `innodb_lock_wait_timeout` (20 s in this lab)
and fails; none succeeds. The API works, at about 18 ms a request. Who is connected:

```sql test
SELECT USER, SUBSTRING_INDEX(HOST, ':', 1) AS client, COMMAND, STATE,
       COUNT(*) AS n, MAX(TIME) AS max_s
FROM performance_schema.processlist
WHERE COMMAND <> 'Daemon'
GROUP BY USER, client, COMMAND, STATE
ORDER BY n DESC;
```

```text
+------------+---------------+------------------+---------------------------------+---+-------+
| USER       | client        | COMMAND          | STATE                           | n | max_s |
+------------+---------------+------------------+---------------------------------+---+-------+
| app        | 192.168.156.5 | Query            | updating                        | 3 |     0 |
| app        | 192.168.156.5 | Query            | executing                       | 3 |     0 |
| repl       | 192.168.156.3 | Binlog Dump GTID | Source has sent all binlog t... | 1 |    56 |
| backoffice | 192.168.156.4 | Sleep            |                                 | 1 |    45 |
| root       | localhost     | Query            | executing                       | 1 |     0 |
+------------+---------------+------------------+---------------------------------+---+-------+
```

Three checkouts `updating` (waiting for a lock), API queries `executing`, and
one `backoffice` session that has been idle for 45 seconds. Idle sessions do
not usually block anyone — unless they are idle *inside a transaction*.

### Checkout: find and release the blocker

```sql test
SELECT wait_age_secs, locked_table, waiting_pid, blocking_pid,
       blocking_trx_age, blocking_query
FROM sys.innodb_lock_waits
LIMIT 3;

SELECT t.trx_started, t.trx_rows_locked, t.trx_rows_modified,
       p.ID, p.USER, p.COMMAND, p.TIME
FROM information_schema.innodb_trx t
JOIN performance_schema.processlist p ON p.ID = t.trx_mysql_thread_id
WHERE p.COMMAND = 'Sleep';
```

```text
+---------------+--------------------+-------------+--------------+------------------+----------------+
| wait_age_secs | locked_table       | waiting_pid | blocking_pid | blocking_trx_age | blocking_query |
+---------------+--------------------+-------------+--------------+------------------+----------------+
|             0 | `shop`.`inventory` |         968 |           25 | 00:00:45         | NULL           |
|             0 | `shop`.`inventory` |         969 |           25 | 00:00:45         | NULL           |
|             0 | `shop`.`inventory` |         970 |           25 | 00:00:45         | NULL           |
+---------------+--------------------+-------------+--------------+------------------+----------------+
+---------------------+-----------------+-------------------+----+------------+---------+------+
| trx_started         | trx_rows_locked | trx_rows_modified | ID | USER       | COMMAND | TIME |
+---------------------+-----------------+-------------------+----+------------+---------+------+
| 2026-10-13 11:11:04 |             148 |                50 | 25 | backoffice | Sleep   |   45 |
+---------------------+-----------------+-------------------+----+------------+---------+------+
```

Every waiter waits for the same session. `blocking_query` is `NULL` because it
is not running anything: it ran something earlier and never committed. What
it ran is in the statement history:

```sql test
SELECT th.PROCESSLIST_ID, h.SQL_TEXT
FROM performance_schema.events_statements_history h
JOIN performance_schema.threads th USING (THREAD_ID)
WHERE th.PROCESSLIST_USER = 'backoffice'
ORDER BY h.EVENT_ID;
```

```text
+----------------+-----------------------------------------------------------------------------------------------------+
| PROCESSLIST_ID | SQL_TEXT                                                                                            |
+----------------+-----------------------------------------------------------------------------------------------------+
|             25 | select @@version_comment limit 1                                                                    |
|             25 | select $$                                                                                           |
|             25 | START TRANSACTION                                                                                   |
|             25 | UPDATE inventory SET on_hand = on_hand + 10 WHERE warehouse = 'TLL' AND product_id BETWEEN 1 AND 50 |
+----------------+-----------------------------------------------------------------------------------------------------+
```

The Tallinn stock correction from `#warehouse`: 50 rows changed, 148 locked.
The extra 98 belong to the other warehouses. Look at the locks themselves:

```sql test
SELECT SUBSTRING_INDEX(l.LOCK_DATA, ', ', -1) AS warehouse,
       l.LOCK_MODE, COUNT(*) AS records
FROM performance_schema.data_locks l
JOIN performance_schema.threads th USING (THREAD_ID)
WHERE th.PROCESSLIST_USER = 'backoffice' AND l.LOCK_TYPE = 'RECORD'
GROUP BY warehouse, l.LOCK_MODE
ORDER BY warehouse, l.LOCK_MODE;
```

```text
+-----------+---------------+---------+
| warehouse | LOCK_MODE     | records |
+-----------+---------------+---------+
| 'HEL'     | X             |      49 |
| 'RIX'     | X             |      49 |
| 'TLL'     | X             |      49 |
| 'TLL'     | X,REC_NOT_GAP |       1 |
+-----------+---------------+---------+
```

The primary key is `(product_id, warehouse)`, and every product is stocked in
three warehouses. `EXPLAIN` on the `UPDATE` shows a `range` scan on
`PRIMARY` with `key_len` 16, both key parts, so the scan runs from
`(1, 'TLL')` to `(50, 'TLL')` in key order. It locks every record it reads,
changed or not: `(1, 'TLL')` itself (a record-only lock, `REC_NOT_GAP`),
then all three warehouses of products 2 to 50 (next-key locks, `X`). That is
1 + 49 × 3 = 148; the rows of Helsinki and Riga for product 1 sit before the
start of the range and are not locked. In real life you would ask the warehouse colleague whether to commit
or abandon it. Here they are in a meeting, checkout is down, and an
uncommitted correction can be redone — so kill the session; InnoDB rolls the
50 rows back. Record that the stock correction must be re-applied.

```bash test
blocker="$(./lab sql -N -e "
  SELECT p.ID FROM information_schema.innodb_trx t
  JOIN performance_schema.processlist p ON p.ID = t.trx_mysql_thread_id
  WHERE p.USER = 'backoffice' AND p.COMMAND = 'Sleep' AND t.trx_rows_locked > 0")"
./lab sql -e "KILL $blocker"
```

### Reports: find out why the replica stopped

```sql test replica
SELECT c.SERVICE_STATE AS io, a.SERVICE_STATE AS applier,
       w.LAST_ERROR_NUMBER AS err, w.APPLYING_TRANSACTION, w.LAST_ERROR_MESSAGE
FROM performance_schema.replication_connection_status c
JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)
JOIN performance_schema.replication_applier_status_by_worker w USING (CHANNEL_NAME)
WHERE w.LAST_ERROR_NUMBER <> 0\G
```

```text
*************************** 1. row ***************************
                  io: ON
             applier: OFF
                 err: 1032
APPLYING_TRANSACTION: bb26185f-c6f6-11f1-b1df-4630364cc63e:46
  LAST_ERROR_MESSAGE: Worker 1 failed executing transaction 'bb26185f-c6f6-11f1-b1df-4630364cc63e:46'
                      at source log binlog.000003, end_log_pos 60194034; Could not execute
                      Update_rows event on table shop.payments; Can't find record in 'payments',
                      Error_code: 1032; handler error HA_ERR_KEY_NOT_FOUND; ...
```

The replica receives changes (`io ON`) but stopped applying them. Error 1032:
the primary updated a `shop.payments` row that the replica does not have.
Decode that one transaction from the primary's binary log:

```bash test
gtid="$(./lab sql replica -N -e "SELECT APPLYING_TRANSACTION
          FROM performance_schema.replication_applier_status_by_worker
          WHERE LAST_ERROR_NUMBER <> 0")"
./lab exec primary sh -c "mysqlbinlog --include-gtids='$gtid' \
  --base64-output=DECODE-ROWS -vv /var/lib/mysql/binlog.0* 2>/dev/null | grep '^###'"
```

```text
### UPDATE `shop`.`payments`
### WHERE
###   @1=4242 /* LONGINT meta=0 nullable=0 is_null=0 */
###   @2=4391 /* LONGINT meta=0 nullable=0 is_null=0 */
...
###   @5=2 /* ENUM(1 byte) meta=63233 nullable=0 is_null=0 */
...
### SET
...
###   @5=4 /* ENUM(1 byte) meta=63233 nullable=0 is_null=0 */
```

Payment 4242 (order 4391 — the support ticket) going from `captured` (enum
value 2) to `refunded` (4). Compare both servers:

```bash test
./lab sql --table -e "SELECT * FROM shop.payments WHERE id = 4242"
./lab sql replica --table -e "SELECT COUNT(*) AS on_replica FROM shop.payments WHERE id = 4242"
```

```text
+------+----------+---------------+--------------+----------+---------------------+
| id   | order_id | method        | amount_cents | status   | created_at          |
+------+----------+---------------+--------------+----------+---------------------+
| 4242 |     4391 | bank_transfer |        72379 | refunded | 2024-01-17 00:15:41 |
+------+----------+---------------+--------------+----------+---------------------+
+------------+
| on_replica |
+------------+
|          0 |
+------------+
```

The row was deleted on the replica only — yesterday's clean-up script, run
against the wrong host. Skipping the transaction (committing an empty
transaction with its GTID) would restart replication and leave the payment
missing from every report: the check rejects that. Instead, put the row back
on the replica from the primary's copy, with `sql_log_bin = 0` so that the
repair does not become an errant transaction of its own, then resume. With a
primary key the applier finds the row by key and applies the pending update
on top; the row ends up identical to the primary's.

```bash test
row="$(./lab sql -N -e "SELECT CONCAT_WS(',', id, order_id, QUOTE(method), amount_cents,
                                         QUOTE(status), QUOTE(created_at))
                       FROM shop.payments WHERE id = 4242")"
./lab sql replica -e "
  SET SESSION sql_log_bin = 0;
  SET GLOBAL super_read_only = OFF;
  INSERT INTO shop.payments (id, order_id, method, amount_cents, status, created_at)
  VALUES ($row);
  SET GLOBAL super_read_only = ON;
  START REPLICA;"
```

One payment is what the error showed you. It is not proof that it is the only
one the script deleted: compare the tables (module 6's fingerprint, or a
checksum tool) before you tell finance the reports are right.

### API: find the statement and index it

```sql test
SELECT LEFT(DIGEST_TEXT, 48) AS digest, COUNT_STAR AS calls,
       ROUND(AVG_TIMER_WAIT / 1e9, 1) AS avg_ms,
       ROUND(SUM_ROWS_EXAMINED / COUNT_STAR) AS examined,
       ROUND(SUM_ROWS_SENT / COUNT_STAR) AS sent
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = 'shop'
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 3;
```

```text
+--------------------------------------------------+-------+---------+----------+------+
| digest                                           | calls | avg_ms  | examined | sent |
+--------------------------------------------------+-------+---------+----------+------+
| SELECT `id` , `customer_id` , `total_cents` , `c |  9278 |    18.3 |   200007 |   50 |
| UPDATE `inventory` SET `reserved` = `reserved` + |     6 | 20038.8 |        0 |    0 |
...
```

About 200 000 rows examined to return 50, thousands of times a minute. At
18 ms each it never reaches the 1-second slow log; it is expensive by volume,
not by duration. `EXPLAIN` it (output below with columns trimmed):

```sql test
EXPLAIN SELECT id, customer_id, total_cents, created_at FROM shop.orders
WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50;
```

```text
+----+-------------+--------+------+---------------+------+--------+-----------------------------+
| id | select_type | table  | type | possible_keys | key  | rows   | Extra                       |
+----+-------------+--------+------+---------------+------+--------+-----------------------------+
|  1 | SIMPLE      | orders | ALL  | NULL          | NULL | 199800 | Using where; Using filesort |
+----+-------------+--------+------+---------------+------+--------+-----------------------------+
```

A full scan plus a sort. An index on `(status, created_at)` serves the
equality filter first and then hands rows over already ordered, so the server
reads 50 index entries backwards and stops. Add it online — InnoDB builds a
secondary index in place without blocking reads or writes
([online DDL](https://dev.mysql.com/doc/refman/8.4/en/innodb-online-ddl-operations.html)):

```sql test
ALTER TABLE shop.orders
  ADD INDEX idx_orders_status_created (status, created_at),
  ALGORITHM = INPLACE, LOCK = NONE;

EXPLAIN SELECT id, customer_id, total_cents, created_at FROM shop.orders
WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50;
```

```text
+----+-------------+--------+------+---------------------------+-------+------+----------------------------------+
| id | select_type | table  | type | key                       | ref   | rows | Extra                            |
+----+-------------+--------+------+---------------------------+-------+------+----------------------------------+
|  1 | SIMPLE      | orders | ref  | idx_orders_status_created | const | 5979 | Using where; Backward index scan |
+----+-------------+--------+------+---------------------------+-------+------+----------------------------------+
```

`rows` is the optimizer's estimate for `status = 'pending'`; with `LIMIT 50`
and no filesort, execution stops after 50. The DDL also replicates — another
reason to have fixed the replica first.

### Verify

```bash test
sleep 25
docker logs --tail 7 "${DBRE_PROJECT:-dbre}-shop-app"
./lab check 10-final-incident
```

```text
11:12:25 api-3 GET /v2/orders?status=pending 6480 requests in 10s, avg 1543us
11:12:27 checkout-3 POST /checkout sku=50 200 9ms
11:12:27 checkout-2 POST /checkout sku=20 200 9ms
11:12:27 checkout-1 POST /checkout sku=14 200 10ms
...
Checking 10-final-incident
Checkout (P1)
  PASS the shop application is still running
  PASS nothing is still holding the row locks checkout needs
  PASS a checkout-style update on shop.inventory completes within 5 seconds
API latency (P2)
  PASS the pending-orders API query no longer reads the whole table (key: idx_orders_status_created, rows: 5979)
Reports replica (stale data)
  PASS replication threads on the replica (IO/SQL)
  PASS the replica has applied everything the primary has
  PASS shop.payments is identical on the primary and the replica
  PASS no new errant transactions on the replica
All checks passed.
```

Checkout takes about 10 ms again, and an API request costs about 1.5 ms
instead of 20 (most of what remains is the load generator starting a client
for every batch).

### What the review should find

Three faults, three different kinds of contributing factor — which is what
your review's action items should reflect:

- **Checkout:** a human ran a multi-row update in an interactive session with
  an open transaction and walked away. Contributing: the back-office tool
  allows raw SQL; no alert on long-running or idle-in-transaction sessions;
  the update locked a range wider than the rows it changed.
- **Reports:** a script ran against the replica instead of staging, and
  `super_read_only` did not stop it because the account had the privilege to
  switch it off. Contributing: an account with `SUPER`/`SYSTEM_VARIABLES_ADMIN`
  used by scripts; replication-stopped alert routed nowhere urgent;
  no regular data-consistency check between primary and replica.
- **API:** a new query shipped without an index. Contributing: no `EXPLAIN`
  review for new queries; the slow log threshold too high to see high-volume
  cheap queries; no digest-based alerting.

</details>

Restore the baseline when you have finished (the walkthrough leaves the
scenario solved):

```bash test
./lab scenario reset 10-final-incident
```
