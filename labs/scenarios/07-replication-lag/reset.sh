#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

RUN=/tmp/dbre-07-replication-lag
FP_SQL="$LAB_DIR/datasets/shop/fingerprint.sql"

# 1. Stop the heartbeat loop on the primary and the hung backup session on
#    the replica (pid files first, then any server thread with the marker).
dc exec -T primary bash -c "
  [ -f $RUN/heartbeat.pid ] && kill \$(cat $RUN/heartbeat.pid) 2>/dev/null
  rm -rf $RUN; exit 0"
dc exec -T replica bash -c "
  [ -f $RUN/backup.pid ] && kill \$(cat $RUN/backup.pid) 2>/dev/null
  rm -rf $RUN; exit 0"
for _ in $(seq 20); do
  ids="$(sqlv replica "
    SELECT th.PROCESSLIST_ID
      FROM performance_schema.user_variables_by_thread v
      JOIN performance_schema.threads th USING (THREAD_ID)
     WHERE v.VARIABLE_NAME = 'dbre_scenario'
       AND CAST(v.VARIABLE_VALUE AS CHAR) = '07-replication-lag'")"
  [ -z "$ids" ] && break
  for id in $ids; do sql replica -e "KILL $id" 2>/dev/null || true; done
  sleep 0.5
done

# 2. Undo the price update if it was applied, then drop the scenario schema.
if [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.TABLES
                      WHERE TABLE_SCHEMA = 'lab' AND TABLE_NAME = 'applied'")" = "1" ]; then
  sql primary <<'SQL'
START TRANSACTION;
UPDATE shop.products SET price_cents = price_cents - 100
 WHERE category = 'lighting'
   AND EXISTS (SELECT 1 FROM lab.applied WHERE change_name = 'lighting-price');
DELETE FROM lab.applied WHERE change_name = 'lighting-price';
COMMIT;
SQL
fi
sql primary -e "DROP DATABASE IF EXISTS lab"

# 3. The replica must be running and consistent; restart it if the student
#    stopped it.
sql replica -e "START REPLICA" 2>/dev/null || true
wait_replica_caught_up 180 || warn "replica is behind the primary — run ./lab status"
if [ "$(sql primary -N -B < "$FP_SQL")" != "$(sql replica -N -B < "$FP_SQL")" ]; then
  warn "shop differs between primary and replica — ./lab scenario reset 07-broken-replication rebuilds the replica"
fi
echo "07-replication-lag reset."
