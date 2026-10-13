# Exercise — Point-in-time recovery

`time: ~40 min` · `scenario: 06-pitr`

A clean-up job was meant to delete failed payments older than 2023. It ran
without its date predicate and deleted every failed payment in
`shop.payments`. Nobody noticed for a while: orders kept coming in, some of
them with new failed payments. You have last night's backup and the binary
logs.

Your job: bring `shop` to the state it would be in had the clean-up never
run, without losing anything else written this morning, on the primary
**and** the replica.

## Set up

```bash test
./lab scenario setup 06-pitr
```

Setup reloads the canonical dataset, then:

1. takes the "nightly" backup to `/backups/pitr/shop-full.sql` with
   `mysqldump --single-transaction --source-data=2 --set-gtid-purged=OFF`
   and writes its SHA-256 next to it;
2. writes a morning of orders, order items and payments (some failed), ships
   ten orders, and corrects the amount on some old failed payments;
3. runs the accidental `DELETE`;
4. writes more orders (with new failed payments), ships ten more orders and
   books stock out of the Tallinn warehouse.

Every value is fixed, so your result can be checked exactly. The check
runs `datasets/shop/fingerprint.sql` on both servers and compares it with
the state setup computed for "no accident".

```bash test expect-error
./lab check 06-pitr
```

```text
Checking 06-pitr
  PASS replication is running and the replica has caught up
  FAIL primary: shop differs from the expected state
       6c6
       < payments	194081	416815732936731
       ---
       > payments	184151	395509311193230
       hint: payments are missing: the failed payments, or the ones written after the backup
       hint: if a replay changed nothing: those GTIDs are already executed here (--skip-gtids)
  FAIL replica: shop differs from the expected state
       6c6
       < payments	194081	416815732936731
       ---
       > payments	184151	395509311193230
2 check(s) failed.
```

## Where to restore: decide first

There are two sound ways to do this, and the choice is the first decision
of any real recovery:

| | In place on the primary | Separate instance, then copy back |
|---|---|---|
| What you restore | The whole schema, live | Into a scratch server |
| Replicas | Follow along: restore and replay are replicated | Unaffected until you copy the fix back |
| GTIDs | Already executed here: replay needs `--skip-gtids` | Fresh server: original GTIDs replay as-is |
| Downtime | The schema is wrong while you work | Only the affected table, only at the end |

In this exercise you restore **in place on the primary**, with the replica
attached. It exercises every trap at once: the backup must load with binary
logging on (that is why it was taken with `--set-gtid-purged=OFF`), the
replay must cope with GTIDs that are already executed, and the replica must
end identical without being touched by hand. On a real system with one
damaged table and a business that keeps writing, the separate-instance
route is often kinder: restore and replay on a scratch server up to just
before the bad transaction, then copy the repaired rows back.

<!-- founder-review: which route MoiToi.TECH picks in practice, and when, would help here -->

## Your task

Work on the primary (`./lab shell primary`; inside the container,
`export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"` and the binlogs are in
`/var/lib/mysql`). In order:

1. **Verify the backup** against its checksum before you trust it.
2. **Find the backup's coordinates** in the dump header.
3. **Find the bad transaction's GTID** in the binary logs after those
   coordinates.
4. **Close the current binary log** (`FLUSH BINARY LOGS`) and note which
   files hold the incident window. Anything written after this, including
   your restore, must not be replayed.
5. **Restore the backup** on the primary.
6. **Replay** every binary log from the backup's coordinates through the
   last file of the window, excluding only the bad transaction.
7. **Verify**: `./lab fingerprint primary`, `./lab fingerprint replica`,
   `./lab status`, and finally the check.

Some read-only starting points. The backup and its checksum:

```bash test
./lab shell primary <<'SH'
ls -lh /backups/pitr/
sha256sum -c /backups/pitr/shop-full.sql.sha256
grep -m1 -- '-- CHANGE REPLICATION SOURCE TO' /backups/pitr/shop-full.sql
SH
```

```text
total 39M
-rw-r--r-- 1 root root 39M Oct 13 11:09 shop-full.sql
-rw-r--r-- 1 root root  94 Oct 13 11:09 shop-full.sql.sha256
/backups/pitr/shop-full.sql: OK
-- CHANGE REPLICATION SOURCE TO SOURCE_LOG_FILE='binlog.000004', SOURCE_LOG_POS=60193294;
```

Every transaction since the backup that deleted rows, with its GTID and
how many row images it carries:

```bash test
./lab shell primary <<'SH'
cd /var/lib/mysql
coords="$(grep -m1 -- '-- CHANGE REPLICATION SOURCE TO' /backups/pitr/shop-full.sql)"
file="$(sed -E "s/.*SOURCE_LOG_FILE='([^']+)'.*/\1/" <<<"$coords")"
pos="$(sed -E 's/.*SOURCE_LOG_POS=([0-9]+);/\1/' <<<"$coords")"
mysqlbinlog --start-position="$pos" --base64-output=DECODE-ROWS -v \
    $(ls binlog.[0-9]* | awk -v f="$file" '$1 >= f') \
  | awk -F"'" '/GTID_NEXT=/ { g = $2 } /^### DELETE FROM/ { n[g " " $0]++ }
               END { for (k in n) print n[k], k }'
SH
```

```text
9930 86f6c6b0-c6f6-11f1-a849-02990f9b2f5f:102 ### DELETE FROM `shop`.`payments`
```

One transaction, 9 930 rows: every failed payment, including the ones
written this morning before the accident. That is your bad GTID. (Your UUID and
transaction number differ.)

## Hints

<details>
<summary>Hint 1 — the replay "worked" but nothing changed</summary>

The primary has already executed every GTID in those binary logs, so it
skips them without an error. Lesson section "Binary logs: the bridge to a
point in time".

</details>

<details>
<summary>Hint 2 — the replica stopped with error 1032 or 1062</summary>

Something was loaded on the primary with binary logging off: the replica
never saw it, and the next change to those rows cannot be applied there.
Did the dump you loaded contain `SET @@SESSION.SQL_LOG_BIN= 0`? Reset the
scenario and start again: `./lab scenario reset 06-pitr`, then setup.

</details>

<details>
<summary>Hint 3 — more rows than expected</summary>

The replay window included something twice: your restore (did you flush
the binary log before loading the backup, and stop the replay at the last
file before the flush?), or a second replay attempt on top of the first.
Restore the backup again and replay once.

</details>

<details>
<summary>Hint 4 — the commands</summary>

```text
mysql -uroot -e "FLUSH BINARY LOGS"
mysql -uroot < /backups/pitr/shop-full.sql
mysqlbinlog --start-position=<pos> --exclude-gtids='<bad gtid>' --skip-gtids \
    <first file> ... <last file before the flush> | mysql -uroot
```

One `mysqlbinlog` invocation for all files: `--start-position` applies to
the first file only.

</details>

A reference solution is in `labs/scenarios/06-pitr/solve.sh`. Try first.

## Check

```text
$ ./lab check 06-pitr
Checking 06-pitr
  PASS replication is running and the replica has caught up
  PASS primary: shop matches the expected fingerprint
  PASS replica: shop matches the expected fingerprint
All checks passed.
```

## Questions to answer for yourself

- How long did the restore and replay take? Scale it: the lab's `shop` is
  about 40 MB. What would your RTO be for 400 GB with `mysqldump`?
- Look at `@@GLOBAL.gtid_executed` on the primary now. Which GTIDs did the
  restore and replay create, and is the bad transaction still in the set?
  Why is that correct?
- Which writes would have been lost if the application had kept writing to
  `shop.payments` while you restored? What would you have done about it?

## Reset

```bash test
./lab scenario reset 06-pitr
```

Reset reloads the canonical dataset on the primary, removes
`/backups/pitr`, and rebuilds the replica from the primary if your attempt
left it stopped or divergent.
