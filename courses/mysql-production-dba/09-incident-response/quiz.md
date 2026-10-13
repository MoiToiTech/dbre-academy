# Module 9 — Quiz

Answer each question before opening the answer. If you get one wrong, re-read
the section it points to; the reasoning matters more than the fact.

**1.** Checkout has been failing for four minutes. You have a plausible
mitigation (roll back the release that went out five minutes ago) but you do
not yet understand why the release breaks checkout. What do you do first, and
why?

<details><summary>Answer</summary>

Roll back. Mitigation does not need the root cause; it needs a safe action that
reduces impact, and a rollback of a recent change is usually the safest one
available. Investigate the cause afterwards, with the evidence you saved
(timeline, processlist output, logs). See *How an incident runs*.

</details>

**2.** A server answers `ERROR 1040: Too many connections`. Your monitoring
agent connects as an account with `CONNECTION_ADMIN`. You open a root session
to investigate and are refused with the same error. What has most likely
happened?

<details><summary>Answer</summary>

mysqld allows `max_connections + 1` connections; the single extra one is for
`CONNECTION_ADMIN` (or `SUPER`) accounts. The monitoring agent is already
using it, so there is no slot left for you. Fixes for next time: do not give
monitoring `CONNECTION_ADMIN`, and enable the administrative interface
(`admin_address`), which is not limited by `max_connections`.

</details>

**3.** You kill all 300 idle sessions of the `orders` service on a saturated
server. Thirty seconds later, `Threads_connected` is back at the limit. What
does that tell you, and what is the next step?

<details><summary>Answer</summary>

The client reconnects: a connection pool with no upper bound, or more
instances than the server can serve. `KILL` treated a symptom. Stop or limit
the source — roll back, scale down, or cap the pool — and give each service
its own account with `MAX_USER_CONNECTIONS` so one service cannot take every
slot.

</details>

**4.** Why is `admin_address` not something you can switch on during an
incident on MySQL 8.4?

<details><summary>Answer</summary>

It is read-only (start-up only) and, in 8.4.11, not persistable: `SET
PERSIST_ONLY admin_address = ...` fails with `ERROR 1238 ... non persistent
read only variable`. It has to be set in an option file and needs a restart,
so it must be in place before the incident.

</details>

**5.** After a planned restart mysqld exits immediately. The last error lines
are:

```text
[ERROR] [MY-011087] [Server] Different lower_case_table_names settings for server ('1') and data dictionary ('0').
[ERROR] [MY-010020] [Server] Data Dictionary initialization failed.
```

`my.cnf` does not mention `lower_case_table_names`. Where do you look, and
what is the least destructive fix?

<details><summary>Answer</summary>

`mysqld-auto.cnf` in the data directory: someone ran `SET PERSIST_ONLY
lower_case_table_names = 1`, applied only at the next start. Start a rescue
instance with `--persisted-globals-load=OFF` and no network, run `RESET
PERSIST lower_case_table_names`, shut it down cleanly, start the real server.
Deleting `mysqld-auto.cnf` also works but loses every other persisted setting.

</details>

**6.** While you repaired the primary in question 5 (eight minutes), the
replica's I/O thread stopped. The primary is back. Why has the replica not
reconnected by itself?

<details><summary>Answer</summary>

It retries `SOURCE_RETRY_COUNT` times (default 10), `SOURCE_CONNECT_RETRY`
seconds apart, then gives up and stops the I/O thread. In the lab that is 10 ×
5 seconds. Run `START REPLICA` and check that it catches up.

</details>

**7.** A developer killed a `DELETE` that had been running for 40 minutes. It
has shown `ROLLING BACK` in `information_schema.innodb_trx` for 20 minutes.
Someone suggests restarting mysqld to make it go away. What happens if you do?

<details><summary>Answer</summary>

The rollback does not go away. After the restart InnoDB runs crash recovery
and then continues rolling back the uncommitted transaction (in the
background, but its locks remain until it finishes), and you have also lost
the buffer pool and dropped every other connection. Watch
`trx_rows_modified` count down instead, and next time check its size before
killing a large write.

</details>

**8.** In the crash-recovery demo, the server logged `ready for connections`
*before* `Rollback of non-prepared transactions completed`. What does that
mean for the application?

<details><summary>Answer</summary>

Redo is applied before the server opens; the rollback of uncommitted
transactions runs in the background after it opens. Clients can connect while
it runs, but rows locked by the transaction being rolled back stay locked until
it finishes, so some statements may wait or time out right after a crash.

</details>

**9.** Name two reasons not to fail over to a replica while you are unsure
whether the primary is dead or merely slow.

<details><summary>Answer</summary>

If the primary is alive, you may end up with two writable servers and
diverging data (split brain). The replica may be missing transactions the
primary committed (lag, or a stopped applier), which then become lost writes.
A failover also moves every client at once; it is hard to undo. Fail over on
evidence.

</details>

**10.** Why does `performance_schema.error_log` not help you find out why the
lab primary died last night, while it was down?

<details><summary>Answer</summary>

It only exists while the server is running, and with the error log going to
stderr it only holds the current run: mysqld says *Error-log destination
"stderr" is not a file. Can not restore error log messages from previous run.*
The previous run's last words are in the container log (`docker logs`, `./lab
logs primary`) or, on a server that logs to a file, in that file.

</details>

**11.** The disk holding the data directory is 100% full. A colleague proposes
deleting the oldest `binlog.0000*` files with `rm`. What do you do instead?

<details><summary>Answer</summary>

Check which binary logs every replica (and any backup or CDC tool) still
needs, then `PURGE BINARY LOGS TO '...'` so the server's index stays
consistent. Never remove InnoDB files (`ibdata*`, `undo_*`, `#innodb_redo`,
`*.ibd`) to make room. Then find what grew, and alert on free space early next
time.

</details>

**12.** Before this lab set `stop_grace_period`, `docker compose restart
primary` logged *Database was not shutdown normally!* on the next start,
though nobody killed anything. Why, and how do you avoid it?

<details><summary>Answer</summary>

Compose sends SIGTERM and waits 10 seconds by default before SIGKILL. mysqld
was still closing connections when the timeout expired, so it was killed
mid-shutdown and InnoDB ran crash recovery. Give it time: `docker compose stop
-t 120`, or set `stop_grace_period` for the service, as the lab now does
(`120s`); in Kubernetes, `terminationGracePeriodSeconds` (30 seconds by
default).

</details>
