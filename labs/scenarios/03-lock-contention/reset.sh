#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# 1. Stop the background sessions inside the container (pid files first, then
#    anything left that carries the scenario marker on its command line).
# The script runs in the container's shell, so its $ expansions are meant to
# stay unexpanded here.
# shellcheck disable=SC2016
dc exec -T primary bash -c '
  d=/tmp/dbre-03-lock-contention
  if [ -d "$d" ]; then
    for f in "$d"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  fi
  pkill -f "/scenarios/03-lock-contention/[s]ession.sh" 2>/dev/null
  pkill -f "[d]bre_scenario=.03-lock-contention" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "[d]bre_scenario=.03-lock-contention|03-lock-contention/[s]ession.sh" >/dev/null || break
    sleep 0.5
  done
  pkill -9 -f "[d]bre_scenario=.03-lock-contention|03-lock-contention/[s]ession.sh" 2>/dev/null
  rm -rf "$d"
  exit 0'

# 2. End any server connection still tagged by the scenario.
for _ in $(seq 20); do
  ids="$(sqlv primary "
    SELECT th.PROCESSLIST_ID
      FROM performance_schema.user_variables_by_thread v
      JOIN performance_schema.threads th USING (THREAD_ID)
     WHERE v.VARIABLE_NAME = 'dbre_scenario'
       AND CAST(v.VARIABLE_VALUE AS CHAR) = '03-lock-contention'")"
  [ -z "$ids" ] && break
  for id in $ids; do sql primary -e "KILL $id" 2>/dev/null || true; done
  sleep 0.5
done

# 3. Restore product 42's inventory rows to the generated baseline.
sql primary -e "
  UPDATE shop.inventory
     SET on_hand = CRC32(CONCAT('inv', product_id, warehouse)) % 500,
         reserved = 0,
         updated_at = TIMESTAMP('2025-12-31 23:00:00')
   WHERE product_id = 42"
wait_replica_caught_up 120 || warn "replica is behind the primary — run ./lab status"
echo "03-lock-contention reset."
