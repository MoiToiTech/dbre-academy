# Quiz — Backup, restore and data integrity

Answer each question before opening the answer. If you get one wrong,
re-read the section named in the answer.

**1.** The business accepts losing at most five minutes of orders. You take
a full `mysqldump` every night at 02:00. Is the RPO met? If not, what is
missing?

<details>
<summary>Answer</summary>

No. A nightly dump alone has an RPO of up to 24 hours. To reach five
minutes you need the binary logs since the dump, copied off the host at
least every five minutes (or streamed continuously with
`mysqlbinlog --read-from-remote-server --raw --stop-never`), and binlog
retention longer than the dump interval. See "RPO and RTO choose the
method".

</details>

**2.** A colleague says "we have a replica, so we don't need point-in-time
recovery". What do you answer?

<details>
<summary>Answer</summary>

A replica protects against losing the primary's host, not against
mistakes: an accidental `DELETE` or `DROP TABLE` is replicated within
moments. (A delayed replica, `SOURCE_DELAY`, gives a window, but it is not
a backup either.) See the RPO/RTO table.

</details>

**3.** A schema has 40 InnoDB tables and one MyISAM table. You dump it with
`mysqldump --single-transaction`. What is consistent and what is not?

<details>
<summary>Answer</summary>

The 40 InnoDB tables are dumped from one consistent snapshot. The MyISAM
table is not part of the transaction and may change during the dump, so it
can be inconsistent with the rest. `--single-transaction` is useful only
with transactional tables. See "Consistency: what `--single-transaction`
covers".

</details>

**4.** You restore a dump made with the default `--set-gtid-purged` on the
primary of a replicated pair to repair a table. Restore and checks on the
primary look fine. An hour later the replica stops with error 1032. Why?

<details>
<summary>Answer</summary>

With GTIDs on, the default (`AUTO`) dump starts with
`SET @@SESSION.SQL_LOG_BIN= 0`. The restore was not binary-logged, so the
replica never received it and still has the old rows. The first replicated
change to a row that exists only in the restored version fails with 1032
(row not found), or 1062 for an insert that collides. For an in-place
restore on a replicated primary, use a dump made with
`--set-gtid-purged=OFF`. See "`--set-gtid-purged`: decide what the restore
should do".

</details>

**5.** Does `--set-gtid-purged=COMMENTED` produce a dump whose load is
binary-logged?

<details>
<summary>Answer</summary>

No. It comments out the `SET @@GLOBAL.GTID_PURGED` statement but keeps
`SET @@SESSION.SQL_LOG_BIN= 0`. Only `OFF` produces a binary-logged load.
You saw this in the lesson's three-way comparison.

</details>

**6.** You restore last night's dump in place on the primary and run
`mysqlbinlog --start-position=... binlog.000041 binlog.000042 | mysql`. It
finishes in a second with no errors, and nothing changes. What happened?

<details>
<summary>Answer</summary>

The binlog events carry `SET @@SESSION.GTID_NEXT` with GTIDs the server
has already executed, and a server ignores a transaction whose GTID is in
`gtid_executed`, without an error. In place you need `--skip-gtids` (the
replay gets new GTIDs); on a fresh server with the backup's GTID set you
would not. See "Binary logs: the bridge to a point in time".

</details>

**7.** Why exclude the bad transaction with `--exclude-gtids` rather than
with `--stop-position` / `--start-position` around it?

<details>
<summary>Answer</summary>

A GTID names a whole transaction, so it is excluded atomically, in one
`mysqlbinlog` run over all files. Positions are byte offsets: one wrong
number replays half a transaction or skips part of the next, and
`--start-position` applies only to the first file and `--stop-position`
only to the last, so skipping something in the middle needs two runs.
Positions remain the tool when GTIDs are off.

</details>

**8.** `CHECK TABLE` returns `status OK` for every table of a restored
backup. Is the restore verified?

<details>
<summary>Answer</summary>

Only physically: the pages and indexes are intact. It says nothing about
whether the rows are the right rows (a backup of the wrong schema, or a
truncated dump, checks OK). Compare row counts and checksums with the
source (the lab's fingerprint, or `pt-table-checksum`) to verify content.
See "Verification".

</details>

**9.** Name two limits of the CLONE plugin that matter if you use it as a
backup tool.

<details>
<summary>Answer</summary>

Any two of: it copies only InnoDB data (MyISAM and CSV tables arrive
empty); it does not copy binary logs, so point-in-time recovery needs them
from elsewhere; it does not copy configuration; donor and recipient must be
in the same release series; and a local clone lands on the same host, so
it still has to be copied off-host. See "The CLONE plugin".

</details>

**10.** Your backups are encrypted with a key stored in `/etc/backup.key`
on the database host, and copied to an S3 bucket in the same account.
Which two risks remain?

<details>
<summary>Answer</summary>

Whoever gets the host gets the key, so the encryption protects nothing
against that attacker; keep the key in a KMS or secrets manager, away from
the data. And an attacker (or a mistake) with the account's credentials can
delete the bucket's contents; keep a copy in another account or under
object lock. See "Retention, off-host copies and encryption".

</details>
