#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 03-lock-contention"
blocker="$(dc exec -T primary cat /tmp/dbre-03-lock-contention/blocker.connid 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$blocker" ]; then
  fail "scenario is not set up"
  hint "run ./lab scenario setup 03-lock-contention first"
  check_result; exit
fi

# 1. The idle transaction that held the locks is gone.
alive="$(sqlv primary "SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_ID = $blocker")"
if [ "$alive" = "0" ]; then
  pass "the blocking connection is gone"
else
  fail "the blocking connection is still connected"
  hint "sys.innodb_lock_waits shows who blocks whom: look at blocking_pid and blocking_query"
  hint "an idle session (Command = Sleep) cannot be stopped with KILL QUERY"
fi

# 2. Nobody is waiting for a row lock any more. The application's retries may
#    need a moment to get through once the blocker has rolled back.
waits=1
for _ in $(seq 10); do
  waits="$(sqlv primary 'SELECT COUNT(*) FROM performance_schema.data_lock_waits')"
  [ "$waits" = "0" ] && break
  sleep 0.5
done
if [ "$waits" = "0" ]; then pass "no session is waiting for a row lock"
else fail "$waits lock wait(s) remain in performance_schema.data_lock_waits"; fi

# 3. The reservations the application was retrying went through.
for _ in $(seq 10); do
  done_count="$(sqlv primary "SELECT COUNT(*) FROM shop.inventory
                              WHERE product_id = 42 AND warehouse IN ('TLL','HEL') AND reserved = 1")"
  [ "$done_count" = "2" ] && break
  sleep 0.5
done
if [ "$done_count" = "2" ]; then
  pass "the application's reservations for TLL and HEL were committed"
else
  fail "the reservations for product 42 in TLL and HEL have not been committed yet"
  hint "SELECT warehouse, reserved FROM shop.inventory WHERE product_id = 42"
fi

check_result
