# Challenge #001 — solution and instructor guide

> **Spoilers.** This is the answer. If you are solving the challenge, go back
> to [the briefing](../README.md) until `./challenge verify` passes.

## The answer in one paragraph

The analytics team's export connected with `autocommit = 0`, ran one SELECT
at night and never committed. Its connection is idle (`Sleep`), but its
transaction is open, and so is the consistent-read snapshot that SELECT
created. While that snapshot exists, InnoDB's purge cannot remove the old row
versions created after it — including the delete-marked entries the outbox
workers leave behind in the `(status, id)` index every time they mark a
message `sent`. By morning there are about 400,000 of them sitting in front
of the few really pending messages. Every claim walks through all of them and,
because it is a locking read, locks every one. Nothing was deployed: the data
changed, and one forgotten session stopped the database from cleaning up after
it. The fix is to end that session — after proving it is safe — and to make
the condition visible so it never lasts a night again.

## The mechanism

Three documented behaviours of InnoDB combine:

1. **Updating an indexed column leaves the old index entry behind.** "When a
   secondary index column is updated, old secondary index records are
   delete-marked, new records are inserted, and delete-marked records are
   eventually purged."
   ([InnoDB Multi-Versioning](https://dev.mysql.com/doc/refman/8.4/en/innodb-multi-versioning.html))
   Every `UPDATE outbox SET status = 'sent'` turns a `('pending', id)` entry
   into a delete-marked one and adds `('sent', id)`.
2. **An open snapshot stops purge.** Undo data "can be discarded only after
   there is no transaction present for which InnoDB has assigned a snapshot
   that in a consistent read could require the information in the update undo
   log". The manual's advice: "commit transactions regularly, including
   transactions that issue only consistent reads." (same page). In
   `REPEATABLE READ`, the first consistent read of a transaction establishes
   the snapshot, and the transaction keeps it until it ends
   ([Consistent Nonlocking Reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)).
   With `autocommit = 0`, the export's single SELECT opened a transaction
   that nothing ever closed.
3. **Locking reads lock what they scan.** "A locking read, an UPDATE, or a
   DELETE generally set record locks on every index record that is scanned in
   the processing of an SQL statement."
   ([Locks Set by Different SQL Statements](https://dev.mysql.com/doc/refman/8.4/en/innodb-locks-set.html))
   The claim, `UPDATE … WHERE status = 'pending' ORDER BY id LIMIT 10`, scans
   the `pending` range of the index from the smallest id — and the
   delete-marked entries are in that range.

The manual describes the general shape too: "If you insert and delete rows in
smallish batches at about the same rate in the table, the purge thread can
start to lag behind and the table can grow bigger and bigger because of all
the "dead" rows, making everything disk-bound and very slow." A queue table
is exactly that workload.

Why it was invisible from the outside: the default `wait_timeout` is 28,800
seconds — eight hours — so an idle connection survives the night. The
transaction modified nothing, so it held no row locks and blocked no one
directly. CPU stayed low because walking an in-memory index is cheap per
entry; it is the number of entries that hurts.

## What the evidence looks like

Numbers observed in this lab on one machine (MySQL 8.4.11, arm64, Docker
Desktop); timings will differ on yours, counts will be close.

| Signal | During the incident | After the fix |
|---|---|---|
| Claim statement, average latency (`./challenge status`) | ~19–22 ms, rising as the day goes on | ~4 ms (mostly the durable commit) |
| Claim statement, rows examined per call | ~4.6 | ~4.6 |
| Row locks taken by one claim of 10 messages (`performance_schema.data_locks`) | ~400,000 | 2–30 |
| `History list length` (`SHOW ENGINE INNODB STATUS`) | ~40,000 and growing | single digits |
| `EXPLAIN` row estimate for `status = 'pending'` | ~200,000 | the real backlog |
| Oldest transaction (`information_schema.innodb_trx`) | the `analytics` connection, `Sleep`, `trx_rows_modified = 0`, open since night | none older than a second |

The two traps are in the second row and the `EXPLAIN` plan: the statement
reports examining a handful of rows and uses the right index, so "missing
index" and "bad plan" look ruled out — correctly. The `EXPLAIN` *estimate* is
the first honest number: about 200,000 rows for a backlog of a few messages.

## A good diagnostic path

1. **Symptom.** `./challenge status` or `sys.statement_analysis`: the claim
   UPDATE's latency is far above what 4–5 rows examined would cost. Lock time
   is low, so it is not waiting on another worker — it is doing work.
2. **Plan.** `EXPLAIN` uses `idx_status_id` with `ref` on `status`. Fine —
   except the row estimate, which is absurd for a queue that is nearly empty.
3. **Work the counter does not show.** Run the claim in a transaction and
   count `performance_schema.data_locks` for it: hundreds of thousands of
   record locks for ten rows. The index range for `pending` is enormous.
4. **Why the range is enormous.** `SHOW ENGINE INNODB STATUS`, `TRANSACTIONS`
   section: `History list length` in the tens of thousands. Purge is not
   keeping up — or is not allowed to.
5. **Who stops purge.** `information_schema.innodb_trx` ordered by
   `trx_started`: one transaction from the night, owned by `analytics`, whose
   connection is in `Sleep`.
6. **Prove it is safe to end.** `trx_rows_modified = 0` and
   `trx_rows_locked = 0`: it wrote nothing, so its rollback is instant and
   loses nothing. It is a reporting connection, not the order service. In real
   life: tell its owner first if you can reach them, and save the evidence —
   the `innodb_trx` row and the process list — before you act.
7. **Act.** `KILL <id>;` — this ends the connection and rolls back its
   transaction ([KILL](https://dev.mysql.com/doc/refman/8.4/en/kill.html)).
8. **Prove it holds.** Watch `History list length` fall and the claim's lock
   count drop to a few dozen, then run `./challenge verify`. It also checks
   that no transaction from before the incident is still open, because that
   is what makes the fix hold.

`instructor/solve.sh` is the scripted version of steps 5–7; CI runs it.

## Wrong turns, and why they fail

| Attempt | What happens |
|---|---|
| Add an index / change the index | The index is right. Dropping `idx_status_id` makes the claim scan the whole table instead; `verify` rejects a changed index. |
| `ANALYZE TABLE` | Refreshes estimates; the delete-marked entries stay. No change in latency (observed). |
| `OPTIMIZE TABLE outbox` | Rebuilds the table without the dead entries, so the claim is fast for a moment (observed: 33 locks right after). The snapshot is still open, so the entries pile up again (observed: 2,683 locks a minute later, growing). `verify` fails: the cause is still present. |
| Bigger buffer pool, more CPU | The work is per index entry, in memory; more resources barely move it. |
| Kill or restart the order service's workers | They are the victims. Their connections hold nothing for long. |
| Delete old `sent` messages | Deletes create more delete-marked entries that purge cannot remove yet, and `verify` rejects lost history. |
| Restart MySQL | Works — it ends every connection, including the culprit. It also drops every client, empties the buffer pool and destroys the evidence of what happened. Ending one idle session is the smaller, reversible-in-spirit action. |

## Stopping it happening again

- **Alert on the age of the oldest transaction**, from
  `information_schema.innodb_trx` (`trx_started`), and on
  `trx_rseg_history_len` in `information_schema.innodb_metrics`. Either one
  would have paged hours before customers noticed.
- **Keep analytics off the primary.** A replica serves the same data, and its
  snapshots do not hold back purge on the primary.
- **Close transactions in clients.** Run reporting tools with autocommit on,
  or make them commit after each query. MySQL 8.4 has no setting that ends an
  idle *transaction*; `wait_timeout` ends idle *connections*, and its default
  is eight hours. A per-session `SET SESSION wait_timeout = …` in the
  reporting tool's connection setup is a reasonable guard.
- **Know the queue pattern's weak spot.** Hot queue tables that update an
  indexed status column depend on purge more than any other table. If purge
  is held back, they degrade first.
- `innodb_max_purge_lag` (default 0, off) can slow writers when purge falls
  behind. It throttles the symptom's growth; it does not remove the cause.

## Running this with a group

- Give 20–40 minutes. Most people spend the first ten proving it is not a
  missing index — that is part of the lesson.
- Hand out hints on request, in order; hint 2 is the turning point.
- Debrief on two questions: *which counter misled you?* and *what would you
  alert on?*
- `./challenge reset` returns a participant to the start in about 30 seconds.

<!-- founder-review: a short, sanitised story of a long-open snapshot or purge lag seen in production would make the debrief land; no employer or client detail. -->

## Known limitations

- The night is replayed fast at start (about 40,000 small transactions);
  during that replay only, commits are not flushed to disk. The server's
  durability settings are back to their defaults before the incident starts.
- Latency numbers depend on the machine and on Docker's storage; the lock
  count and `History list length` are the reliable signals, and they are what
  `verify` and CI check.
- One MySQL server, no replica: "move analytics to a replica" is discussed,
  not demonstrated.
