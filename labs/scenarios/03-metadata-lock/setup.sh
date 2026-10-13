#!/usr/bin/env bash
# summary: A deploy's ALTER TABLE hangs and every query on shop.customers queues behind it
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean state even if a previous run was not reset.
bash "$LAB_DIR/scenarios/03-metadata-lock/reset.sh" >/dev/null

run() { dc exec -d primary bash /scenarios/03-metadata-lock/session.sh "$@"; }

# wait_for <count> <sql returning a count>
wait_for() {
  for _ in $(seq 30); do
    [ "$(sqlv primary "$2")" -ge "$1" ] && return 0
    sleep 0.5
  done
  die "scenario sessions did not start — run ./lab scenario reset 03-metadata-lock"
}

marked_threads="
  SELECT th.PROCESSLIST_ID FROM performance_schema.user_variables_by_thread v
    JOIN performance_schema.threads th USING (THREAD_ID)
   WHERE v.VARIABLE_NAME = 'dbre_scenario'"

# 1. A reporting job opens a transaction, reads customers and goes idle.
run report
wait_for 1 "SELECT COUNT(*) FROM information_schema.INNODB_TRX
             WHERE trx_mysql_thread_id IN ($marked_threads)"
blocker="$(sqlv primary "SELECT trx_mysql_thread_id FROM information_schema.INNODB_TRX
                          WHERE trx_mysql_thread_id IN ($marked_threads)")"
dc exec -T primary bash -c "echo $blocker > /tmp/dbre-03-metadata-lock/blocker.connid"

# 2. The deploy starts its migration, which queues for an exclusive MDL.
run migration
wait_for 1 "SELECT COUNT(*) FROM performance_schema.processlist
             WHERE STATE = 'Waiting for table metadata lock' AND INFO LIKE 'ALTER TABLE%'"

# 3. Ordinary API reads now queue behind the pending ALTER.
for n in 101 102 103 104; do run api "$n"; done
wait_for 5 "SELECT COUNT(*) FROM performance_schema.processlist
             WHERE STATE = 'Waiting for table metadata lock'"

cat <<'MSG'
Scenario 03-metadata-lock is running.

  A deploy started a schema migration on shop.customers a moment ago. The
  migration has not finished, and now customer look-ups from the API hang
  too: none of them returns, none of them times out.

  Find out what everything is waiting for, get the API answering again and
  let the migration finish. Then: ./lab check 03-metadata-lock
MSG
