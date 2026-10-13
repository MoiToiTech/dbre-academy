#!/usr/bin/env bash
# Reference fix: restore last night's backup in place on the primary
# (binary-logged, so the replica follows), then replay this morning's binary
# logs from the backup's coordinates, skipping only the accidental DELETE.
#
# In place is an offline technique: it is safe here only because no writer
# is connected (the lab's workload is stopped). On a live system, restore to
# a separate instance instead; see the exercise.
. "$LAB_DIR/scripts/lib.sh"

dc exec -T -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" primary bash -s <<'SH'
set -euo pipefail
cd /var/lib/mysql
DUMP=/backups/pitr/shop-full.sql

# 0. The backup is the one we think it is.
sha256sum -c "$DUMP.sha256"

# 1. No writer may be connected: a write after the boundary below would be
#    overwritten by the restore and missed by the replay. In the lab the only
#    other sessions are the replica's binlog dump and the idle event
#    scheduler. (Not super_read_only: it would block this restore too.)
others="$(mysql -uroot -N -e "SELECT COUNT(*) FROM performance_schema.processlist
  WHERE ID <> CONNECTION_ID() AND USER NOT IN ('system user', 'event_scheduler')
    AND COMMAND <> 'Binlog Dump GTID'")"
open_trx="$(mysql -uroot -N -e "SELECT COUNT(*) FROM information_schema.innodb_trx")"
[ "$others" = 0 ] && [ "$open_trx" = 0 ] \
  || { echo "writers still connected ($others) or transactions open ($open_trx)" >&2; exit 1; }

# 2. The replay boundary: close the current binary log, so everything up to
#    now is in closed files.
mysql -uroot -e "FLUSH BINARY LOGS"
last="$(mysql -uroot -N -e "SHOW BINARY LOGS" | tail -2 | head -1 | cut -f1)"

# 3. Where the backup's snapshot sits in the binary log.
coords="$(grep -m1 -- '-- CHANGE REPLICATION SOURCE TO' "$DUMP")"
file="$(sed -E "s/.*SOURCE_LOG_FILE='([^']+)'.*/\1/" <<<"$coords")"
pos="$(sed -E 's/.*SOURCE_LOG_POS=([0-9]+).*/\1/' <<<"$coords")"
files="$(mysql -uroot -N -e "SHOW BINARY LOGS" | cut -f1 \
         | awk -v f="$file" -v l="$last" '$1 >= f && $1 <= l')"
echo "replaying from $file:$pos through $last"

# 4. The GTID of the transaction that deleted from shop.payments.
# shellcheck disable=SC2086
bad="$(mysqlbinlog --start-position="$pos" --base64-output=DECODE-ROWS -v $files \
       | awk '/SET @@SESSION.GTID_NEXT=/ { split($0, q, "'\''"); g = q[2] }
              /^### DELETE FROM `shop`.`payments`/ && !n++ { print g }')"
[ -n "$bad" ] || { echo "accidental DELETE not found" >&2; exit 1; }
echo "skipping $bad"

# 5. Keep the evidence where the restore cannot touch it.
mkdir -p /backups/pitr/evidence
# shellcheck disable=SC2086
cp $files /backups/pitr/evidence/
printf 'backup coordinates: %s:%s\nbad transaction: %s\ngtid_executed before restore: %s\n' \
  "$file" "$pos" "$bad" "$(mysql -uroot -N -e 'SELECT @@GLOBAL.gtid_executed')" \
  > /backups/pitr/evidence/NOTES

# 6. Restore the backup (binary-logged: the replica receives it too).
mysql -uroot < "$DUMP"

# 7. Replay everything since the backup except the bad transaction. The
#    original GTIDs are already executed here, so they must be dropped
#    (--skip-gtids) or the server would silently skip every transaction.
# shellcheck disable=SC2086
mysqlbinlog --start-position="$pos" --exclude-gtids="$bad" --skip-gtids $files | mysql -uroot
SH
wait_replica_caught_up 300 || die "replica did not catch up"
