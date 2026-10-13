#!/usr/bin/env bash
# summary: Stock reservations time out — an idle transaction holds row locks on shop.inventory
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean state even if a previous run was not reset.
bash "$LAB_DIR/scenarios/03-lock-contention/reset.sh" >/dev/null

# The sessions run inside the primary container (docker compose exec -d), so
# they survive this script. session.sh records their pids for reset.sh.
dc exec -d primary bash /scenarios/03-lock-contention/session.sh blocker

blocker=""
for _ in $(seq 30); do
  blocker="$(sqlv primary "
    SELECT t.trx_mysql_thread_id
      FROM information_schema.INNODB_TRX t
      JOIN performance_schema.threads th ON th.PROCESSLIST_ID = t.trx_mysql_thread_id
      JOIN performance_schema.user_variables_by_thread v ON v.THREAD_ID = th.THREAD_ID
     WHERE v.VARIABLE_NAME = 'dbre_scenario' AND t.trx_rows_modified = 3")"
  [ -n "$blocker" ] && break
  sleep 0.5
done
[ -n "$blocker" ] || die "the blocking session did not start — run ./lab scenario reset 03-lock-contention"
dc exec -T primary bash -c "echo $blocker > /tmp/dbre-03-lock-contention/blocker.connid"

dc exec -d primary bash /scenarios/03-lock-contention/session.sh victim TLL
dc exec -d primary bash /scenarios/03-lock-contention/session.sh victim HEL

for _ in $(seq 30); do
  [ "$(sqlv primary 'SELECT COUNT(*) FROM performance_schema.data_lock_waits')" -ge 2 ] && break
  sleep 0.5
done
[ "$(sqlv primary 'SELECT COUNT(*) FROM performance_schema.data_lock_waits')" -ge 2 ] \
  || die "the waiting sessions did not start — run ./lab scenario reset 03-lock-contention"

cat <<'MSG'
Scenario 03-lock-contention is running.

  The stock-reservation API is timing out for product 42. Its UPDATEs on
  shop.inventory fail with "Lock wait timeout exceeded" after 20 seconds,
  and the application keeps retrying.

  Find the session that is blocking them, decide what to do with it, and
  make the reservations go through. Then: ./lab check 03-lock-contention
MSG
