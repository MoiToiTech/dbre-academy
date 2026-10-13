# Module 3 — Exercises

Two incidents, both caused by a transaction that nobody ended. In each, work
out who is blocking whom from the server's own tables before you change
anything. Allow about 15 minutes per exercise.

Each scenario has a reference fix in `labs/scenarios/<name>/solve.sh`. Try
first; if you are stuck, read it, or run it with
`./lab scenario solve <name>`.

## Exercise 1 — Stock reservations time out (`03-lock-contention`)

Start the incident:

```bash test
./lab scenario setup 03-lock-contention
```

```text
Scenario 03-lock-contention is running.

  The stock-reservation API is timing out for product 42. Its UPDATEs on
  shop.inventory fail with "Lock wait timeout exceeded" after 20 seconds,
  and the application keeps retrying.

  Find the session that is blocking them, decide what to do with it, and
  make the reservations go through. Then: ./lab check 03-lock-contention
```

The scenario runs three application sessions, all as the `app` account,
inside the primary container. They keep running until you fix the problem or
reset the scenario.

### Your tasks

1. List the application's sessions. Which are working, which are waiting,
   which are idle?

   ```sql test
   SELECT PROCESSLIST_ID AS id, PROCESSLIST_COMMAND AS command,
          PROCESSLIST_TIME AS time, PROCESSLIST_STATE AS state
     FROM performance_schema.threads
    WHERE PROCESSLIST_USER = 'app';
   ```

2. Build the wait graph from `sys.innodb_lock_waits`. Which `blocking_pid`
   holds the locks? What is its `blocking_query`, and what does that tell
   you?
3. Look up that session's transaction in `information_schema.INNODB_TRX`.
   How old is it, how many rows has it locked and modified?
4. Look at product 42's stock with a plain `SELECT`. Can you see the
   blocker's uncommitted reservation? Why, or why not?
5. Resolve the incident. Then confirm that nothing waits any more and that
   the application's reservations went through:

   ```bash
   ./lab check 03-lock-contention
   ```

Expected output once solved:

```text
Checking 03-lock-contention
  PASS the blocking connection is gone
  PASS no session is waiting for a row lock
  PASS the application's reservations for TLL and HEL were committed
All checks passed.
```

Before the fix, the check fails:

```bash test expect-error
./lab check 03-lock-contention
```

<details>
<summary>Hint 1</summary>

The waiting sessions' ids change every 20 seconds or so: each time an
`UPDATE` times out, the application reconnects and tries again. The
blocker's id does not change.

</details>

<details>
<summary>Hint 2</summary>

`blocking_query` is `NULL` and the blocker's command is `Sleep`: it is idle
in a transaction. `KILL QUERY` stops a running statement, and there is none.

</details>

<details>
<summary>Discussion</summary>

A wait graph from the lab looks like this (your ids differ):

```text
+-------------+--------------+----------------+---------------+
| waiting_pid | blocking_pid | blocking_query | wait_age_secs |
+-------------+--------------+----------------+---------------+
|         877 |          863 | NULL           |             1 |
|         876 |          863 | NULL           |             1 |
+-------------+--------------+----------------+---------------+
```

Session 863 opened a transaction, reserved stock for product 42 in all three
warehouses and then stopped talking to the database. A plain `SELECT` shows
`reserved = 0`, because a consistent read does not see another transaction's
uncommitted changes. `KILL 863` ends the connection, InnoDB rolls back its
transaction, and the waiting `UPDATE`s get their locks.

In a real incident, `KILL` is the mitigation, not the fix. The follow-up
questions are: which code path opened that transaction and never committed
it, and why did nothing time it out? Shorter `wait_timeout` for the
application account, explicit transaction scoping in the code, and an alert
on the age of the oldest transaction all help.

</details>

Reset the scenario when you are done (also when you did not solve it):

```bash test
./lab scenario reset 03-lock-contention
```

## Exercise 2 — A migration takes the table down (`03-metadata-lock`)

```bash test
./lab scenario setup 03-metadata-lock
```

```text
Scenario 03-metadata-lock is running.

  A deploy started a schema migration on shop.customers a moment ago. The
  migration has not finished, and now customer look-ups from the API hang
  too: none of them returns, none of them times out.

  Find out what everything is waiting for, get the API answering again and
  let the migration finish. Then: ./lab check 03-metadata-lock
```

### Your tasks

1. List the sessions and their states:

   ```sql test
   SELECT PROCESSLIST_ID AS id, PROCESSLIST_USER AS user,
          PROCESSLIST_COMMAND AS command, PROCESSLIST_STATE AS state,
          LEFT(PROCESSLIST_INFO, 40) AS info
     FROM performance_schema.threads
    WHERE PROCESSLIST_USER IN ('app', 'root')
      AND PROCESSLIST_ID <> CONNECTION_ID();
   ```

   ```text
   +------+------+---------+---------------------------------+------------------------------------------+
   | id   | user | command | state                           | info                                     |
   +------+------+---------+---------------------------------+------------------------------------------+
   |  824 | app  | Sleep   | NULL                            | NULL                                     |
   |  829 | app  | Query   | Waiting for table metadata lock | SELECT id, email, status FROM customers  |
   |  830 | app  | Query   | Waiting for table metadata lock | SELECT id, email, status FROM customers  |
   |  831 | app  | Query   | Waiting for table metadata lock | SELECT id, email, status FROM customers  |
   |  832 | app  | Query   | Waiting for table metadata lock | SELECT id, email, status FROM customers  |
   |  827 | root | Query   | Waiting for table metadata lock | ALTER TABLE customers ADD COLUMN marketi |
   +------+------+---------+---------------------------------+------------------------------------------+
   ```

2. Why do the `SELECT`s wait? They take no row locks, and nobody is writing
   to `shop.customers`.
3. Use `sys.schema_table_lock_waits` and
   `performance_schema.metadata_locks` to find the root blocker. Careful: the
   view lists more than one `blocking_pid`.
4. Why does nothing time out? Check `@@lock_wait_timeout`.
5. Resolve it so that the API reads complete **and** the migration finishes,
   then run `./lab check 03-metadata-lock`.

Before the fix, the check fails:

```bash test expect-error
./lab check 03-metadata-lock
```

<details>
<summary>Hint</summary>

Which `blocking_pid` in `sys.schema_table_lock_waits` never appears as a
`waiting_pid`? In `metadata_locks`, which thread holds a `GRANTED` lock on
`customers` but is not waiting for anything?

</details>

<details>
<summary>Discussion</summary>

The idle `app` session (`Sleep`) started a transaction and read
`shop.customers`, so it holds a `SHARED_READ` metadata lock until it commits.
The `ALTER TABLE` needs an `EXCLUSIVE` lock and queues. Every `SELECT` that
arrives after it queues behind the pending exclusive request. With
`lock_wait_timeout` at its default of one year, none of them gives up.

Ending the idle session (`KILL <id>`) lets the `ALTER` run (adding a column
is an instant operation here) and the reads complete straight after.

Killing the `ALTER` instead also gets the API answering, and in a real
incident it can be the safer first move when you do not know what the idle
session is. The migration then has to run again; do it with a guard, so a
blocked migration fails fast instead of queueing the application behind it:

```sql
SET SESSION lock_wait_timeout = 5;
ALTER TABLE shop.customers ADD COLUMN marketing_opt_in TINYINT NOT NULL DEFAULT 0;
```

and retry it when the table is free. Most migration frameworks let you set
session variables per migration; put that in your deploy pipeline.

</details>

```bash test
./lab scenario reset 03-metadata-lock
```

## Stretch: watch the history list grow

Without a scenario: in one terminal, open `./lab sql` and run
`START TRANSACTION WITH CONSISTENT SNAPSHOT;`, then leave it. In a second
terminal, run the 1 000-transaction loop from section 4 of the lesson two or
three times, checking `SHOW ENGINE INNODB STATUS\G` in between. Then end the
first session with `COMMIT` and watch `Purge done for trx's n:o` catch up.
Which query from this module would have found the idle session for you?
