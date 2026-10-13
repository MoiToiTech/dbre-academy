#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# 1. Stop the background sessions inside the container (pid files first, then
#    anything left that carries the scenario marker on its command line).
# The script runs in the container's shell, so its $ expansions are meant to
# stay unexpanded here.
# shellcheck disable=SC2016
dc exec -T primary bash -c '
  d=/tmp/dbre-03-metadata-lock
  if [ -d "$d" ]; then
    for f in "$d"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  fi
  pat="[d]bre_scenario=.03-metadata-lock|03-metadata-lock/[s]ession.sh"
  pkill -f "$pat" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$pat" >/dev/null || break
    sleep 0.5
  done
  pkill -9 -f "$pat" 2>/dev/null
  rm -rf "$d"
  exit 0'

# 2. End any server connection still tagged by the scenario (a killed client
#    can leave its server thread behind for a moment).
for _ in $(seq 20); do
  ids="$(sqlv primary "
    SELECT th.PROCESSLIST_ID
      FROM performance_schema.user_variables_by_thread v
      JOIN performance_schema.threads th USING (THREAD_ID)
     WHERE v.VARIABLE_NAME = 'dbre_scenario'
       AND CAST(v.VARIABLE_VALUE AS CHAR) = '03-metadata-lock'")"
  [ -z "$ids" ] && break
  for id in $ids; do sql primary -e "KILL $id" 2>/dev/null || true; done
  sleep 0.5
done

# 3. Undo the migration. ALGORITHM=INPLACE rebuilds the table, which also
#    resets its instant-DDL row version counter (INNODB_TABLES.TOTAL_ROW_VERSIONS).
if [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.COLUMNS
                      WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'customers'
                        AND COLUMN_NAME = 'marketing_opt_in'")" = "1" ]; then
  sql primary -e "ALTER TABLE shop.customers DROP COLUMN marketing_opt_in, ALGORITHM=INPLACE"
fi
wait_replica_caught_up 120 || warn "replica is behind the primary — run ./lab status"
echo "03-metadata-lock reset."
