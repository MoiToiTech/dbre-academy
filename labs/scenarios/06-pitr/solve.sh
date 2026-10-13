#!/usr/bin/env bash
# Reference fix: restore last night's backup in place on the primary
# (binary-logged, so the replica follows), then replay this morning's binary
# logs from the backup's coordinates, skipping only the accidental DELETE.
. "$LAB_DIR/scripts/lib.sh"

dc exec -T -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" primary bash -s <<'SH'
set -euo pipefail
cd /var/lib/mysql
DUMP=/backups/pitr/shop-full.sql

# 0. The backup is the one we think it is.
sha256sum -c "$DUMP.sha256"

# 1. Close the current binary log: everything up to now is in closed files.
mysql -uroot -e "FLUSH BINARY LOGS"
last="$(mysql -uroot -N -e "SHOW BINARY LOGS" | tail -2 | head -1 | cut -f1)"

# 2. Where the backup's snapshot sits in the binary log.
coords="$(grep -m1 -- '-- CHANGE REPLICATION SOURCE TO' "$DUMP")"
file="$(sed -E "s/.*SOURCE_LOG_FILE='([^']+)'.*/\1/" <<<"$coords")"
pos="$(sed -E 's/.*SOURCE_LOG_POS=([0-9]+).*/\1/' <<<"$coords")"
files="$(mysql -uroot -N -e "SHOW BINARY LOGS" | cut -f1 \
         | awk -v f="$file" -v l="$last" '$1 >= f && $1 <= l')"
echo "replaying from $file:$pos through $last"

# 3. The GTID of the transaction that deleted from shop.payments.
# shellcheck disable=SC2086
bad="$(mysqlbinlog --start-position="$pos" --base64-output=DECODE-ROWS -v $files \
       | awk '/SET @@SESSION.GTID_NEXT=/ { split($0, q, "'\''"); g = q[2] }
              /^### DELETE FROM `shop`.`payments`/ && !n++ { print g }')"
[ -n "$bad" ] || { echo "accidental DELETE not found" >&2; exit 1; }
echo "skipping $bad"

# 4. Restore the backup (binary-logged: the replica receives it too).
mysql -uroot < "$DUMP"

# 5. Replay everything since the backup except the bad transaction. The
#    original GTIDs are already executed here, so they must be dropped
#    (--skip-gtids) or the server would silently skip every transaction.
# shellcheck disable=SC2086
mysqlbinlog --start-position="$pos" --exclude-gtids="$bad" --skip-gtids $files | mysql -uroot
SH
wait_replica_caught_up 300 || die "replica did not catch up"
