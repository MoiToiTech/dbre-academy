# Quiz 8 — Monitoring and observability

Answer from memory first, then open the answer.

**1.** A replica's applier thread stops. Your only replication alert is
`mysql_slave_status_seconds_behind_source > 30`. What happens?

<details>
<summary>Answer</summary>

Nothing fires. With the applier stopped, `Seconds_Behind_Source` is
`NULL`; the exporter emits no sample, the series ends, and a comparison on
a missing series is never true. Alert on the thread flags
(`mysql_slave_status_replica_io_running`, `..._replica_sql_running`) as
well as on lag.

</details>

**2.** You copy a popular rule set that uses
`mysql_slave_status_seconds_behind_master`. `promtool check rules` says
SUCCESS. Is the rule working against MySQL 8.4?

<details>
<summary>Answer</summary>

No. The exporter names the metric after the 8.4 column,
`..._seconds_behind_source`. The old name is valid PromQL that matches no
series, so the rule loads and never fires. `promtool check rules` checks
syntax, not that the metrics exist; check names against `/metrics`, and
cover behaviour with `promtool test rules`.

</details>

**3.** `Seconds_Behind_Source` reads 0 on a replica whose network link to
the primary is badly congested. How can that be, and what would show the
real delay?

<details>
<summary>Answer</summary>

It measures the applier against events the receiver has already fetched.
If the receiver is slow, the applier keeps up with the relay log and
reports 0, even though the replica is behind the primary. A heartbeat
(a timestamp written on the primary every second and read on the replica)
or a GTID gap (`GTID_SUBTRACT` of the two `gtid_executed` sets) shows the
real delay.

</details>

**4.** Which grants does the lab's `exporter` account have, and why is it
limited to three connections?

<details>
<summary>Answer</summary>

`PROCESS`, `REPLICATION CLIENT` and `SELECT ON *.*`, as the
`mysqld_exporter` README recommends — no writes, no `SUPER`.
`MAX_USER_CONNECTIONS 3` stops a misbehaving or slow exporter from using up
`max_connections` during the very incident you are monitoring.

</details>

**5.** Which is the better saturation signal, `Threads_connected` or
`Threads_running`? Why?

<details>
<summary>Answer</summary>

`Threads_running`: it counts sessions executing a statement now, including
those waiting for locks, so a sustained high value means work is queuing.
`Threads_connected` is mostly idle pool connections; it matters only near
`max_connections`.

</details>

**6.** During a pile-up of 16 sessions behind one row lock,
`rate(mysql_global_status_innodb_row_lock_waits[1m])` stays around 0.5.
Why is that rate a poor alert for this incident?

<details>
<summary>Answer</summary>

It counts *new* waits per second. Each waiter sits for the whole
`innodb_lock_wait_timeout` before retrying, so the worse the stall, the
fewer new waits start. A gauge of current state —
`Innodb_row_lock_current_waits` or `Threads_running` — captures a pile-up.

</details>

**7.** What does `for: 2m` do in an alerting rule? What would happen
without it?

<details>
<summary>Answer</summary>

The alert stays `pending` until the expression has been true continuously
for two minutes, then becomes `firing`. Without it, any single evaluation
where the expression is true fires the alert — one noisy scrape pages
someone.

</details>

**8.** Give two reasons the buffer pool hit ratio makes a poor paging
alert.

<details>
<summary>Answer</summary>

It is a cause-level metric, not a symptom: users may be served perfectly
well at 98%. And a ratio hides scale: 99.9% of a million requests a second
is still a thousand disk reads a second. Put it on a dashboard next to
`rate(Innodb_buffer_pool_reads)`; page on symptoms.

</details>

**9.** `events_errors_summary_by_user_by_error` shows hundreds of
`ER_PARSE_ERROR` for `root` on a quiet lab. Is something broken?

<details>
<summary>Answer</summary>

No. The `mysql` command-line client sends a probe statement, `select $$`,
on every connection, which the server rejects with error 1064. Error
counters need a baseline and a breakdown by account and error number
before they are alertable.

</details>

**10.** The person paged needs to stop a stall caused by a session idle
inside an open transaction. `KILL QUERY <id>` or `KILL <id>`?

<details>
<summary>Answer</summary>

`KILL <id>`: it ends the connection, so the transaction rolls back and its
locks are released. `KILL QUERY` stops only the statement currently
running; the transaction and its row locks stay — and an idle session has
no running statement to stop at all.

</details>

**11.** Why does a pull-based system like Prometheus need an alert on
`up == 0` in addition to `mysql_up == 0`?

<details>
<summary>Answer</summary>

`mysql_up` is produced by the exporter. If the exporter itself is down or
unreachable, there is no `mysql_up` sample at all and `mysql_up == 0` never
fires; Prometheus records the failed scrape as `up == 0`. Without that
alert, losing the monitoring looks exactly like a healthy, silent system.

</details>
