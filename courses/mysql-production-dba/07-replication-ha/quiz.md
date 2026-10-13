# Quiz — Replication and high availability fundamentals

Answer each question before opening the answer. If you get one wrong,
re-read the section named in the answer.

**1.** `SHOW REPLICA STATUS` shows `Replica_IO_Running: Yes`,
`Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0`. Can the replica
still be minutes behind? Name two ways.

<details>
<summary>Answer</summary>

Yes. `Seconds_Behind_Source` measures the applier against the receiver, so
if the receiver itself is behind (slow network, bandwidth), it shows 0. And
before a large transaction starts applying, it can show 0 and then jump.
Compare GTID sets or use a heartbeat table. See "Measuring lag".

</details>

**2.** On the replica, `Retrieved_Gtid_Set` keeps growing and
`Executed_Gtid_Set` does not. Where is the problem, and where do you look
next?

<details>
<summary>Answer</summary>

In the applier: transactions arrive in the relay log but are not applied.
Look at the worker threads' state (`SHOW PROCESSLIST`,
`performance_schema.replication_applier_status_by_worker`): an error, a
lock wait (`Waiting for global read lock`, `Waiting for table metadata
lock`), or one long transaction others wait behind
(`Waiting for preceding transaction to commit`).

</details>

**3.** What does `SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed,
'<primary's gtid_executed>')` return on a healthy replica, and what does a
non-empty result mean?

<details>
<summary>Answer</summary>

An empty string. Anything it returns is an errant transaction: executed on
the replica but never on the primary. See "Errant transactions".

</details>

**4.** Why does an errant transaction matter if its data change is
harmless?

<details>
<summary>Answer</summary>

Because of failover. When the replica is promoted, the other replicas
auto-position against it and fetch every GTID they lack, including the
errant ones: they are applied everywhere, or, if already purged from the
binary logs, the replicas cannot connect (error 1236) and the failover
fails.

</details>

**5.** The applier stopped with error 1062 on an `INSERT` into `customers`.
A colleague proposes committing an empty transaction with the failing GTID
on the replica. When is that correct, and what is the usual right fix?

<details>
<summary>Answer</summary>

It is correct only if the replica's existing row is already exactly what
the primary's insert would have produced (or the change is provably
irrelevant). Otherwise the replica keeps a different row for ever. The
usual fix is to make the data what it should have been before the
transaction (delete the conflicting row, with `sql_log_bin=0`) and let the
applier run the primary's insert. See "Replication errors: 1062 and 1032".

</details>

**6.** Why should repairs on a replica run with
`SET SESSION sql_log_bin = 0`?

<details>
<summary>Answer</summary>

With binary logging on, the repair is a new transaction with the replica's
own UUID: an errant transaction, created by the fix.

</details>

**7.** A runbook says `SET GLOBAL sql_replica_skip_counter = 1; START
REPLICA;`. What happens on the lab's GTID replica?

<details>
<summary>Answer</summary>

The `SET` succeeds with warning 4016 (it takes effect only for channels
with `ASSIGN_GTIDS_TO_ANONYMOUS_TRANSACTIONS`), `START REPLICA` resets the
counter to 0, nothing is skipped, and a broken applier stops on the same
error again. The manual says it must not be set to a nonzero value with
`gtid_mode=ON`.

</details>

**8.** Semi-synchronous replication is on and a commit returns OK. What is
guaranteed, and what is not?

<details>
<summary>Answer</summary>

Guaranteed: at least `rpl_semi_sync_source_wait_for_replica_count`
replicas have received the transaction and written it to their relay log,
so it exists on more than one server. Not guaranteed: that any replica has
applied it (a semi-sync replica can lag), and anything at all once the
timeout has expired, because the primary then falls back to asynchronous
replication until a replica catches up. Watch
`Rpl_semi_sync_source_status`.

</details>

**9.** What is the difference between `read_only` and `super_read_only`,
and which do you set on a replica?

<details>
<summary>Answer</summary>

`read_only` blocks writes from clients without `CONNECTION_ADMIN` (or
`SUPER`); `super_read_only` blocks those too. Neither blocks the
replication applier. Set both (enabling `super_read_only` forces
`read_only` on), persisted, on every replica.

</details>

**10.** Your primary is unreachable from the application network. You
promote the replica. What must you do before that, and why?

<details>
<summary>Answer</summary>

Fence the old primary: make certain it cannot accept writes (power it off
through the platform API, isolate its network, revoke application access,
or set it `super_read_only` if reachable). It may only be partitioned, not
dead; if clients that can still reach it keep writing, you have two
primaries and diverging data: split brain. See "Failover (unplanned) and
split brain".

</details>

**11.** With `replica_parallel_workers = 4`, why can a single large
transaction still make the whole replica lag?

<details>
<summary>Answer</summary>

`replica_preserve_commit_order=ON` makes workers commit in the primary's
order. Transactions after the large one may execute in parallel but must
wait to commit until it has committed, so everything behind it waits.

</details>
