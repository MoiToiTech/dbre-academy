#!/usr/bin/env bash
# Validates each of the three faults separately. Hints are progressive:
#   ./lab check 10-final-incident                 PASS/FAIL only
#   HINT_LEVEL=1 ./lab check 10-final-incident    where to look
#   HINT_LEVEL=2 ...                              which tool or table
#   HINT_LEVEL=3 ...                              close to the answer
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/10-final-incident/common.sh"

LEVEL="${HINT_LEVEL:-0}"
hints() { # hints "<level 1>" "<level 2>" "<level 3>"
  [ "$LEVEL" -ge 1 ] && hint "$1"
  [ "$LEVEL" -ge 2 ] && hint "$2"
  [ "$LEVEL" -ge 3 ] && hint "$3"
  return 0
}

echo "Checking 10-final-incident"

# --- 1. Checkout -------------------------------------------------------------
echo "Checkout (P1)"
if running "$APP"; then pass "the shop application is still running"
else
  fail "the shop application is still running"
  hints "stopping the application ends the errors by ending checkout: that is an outage, not a mitigation" \
        "restore it with ./lab scenario reset 10-final-incident and start over" \
        "mitigate inside the database instead"
fi

idle="$(sqlv primary "SELECT COUNT(*) FROM information_schema.innodb_trx t
                      JOIN performance_schema.processlist p ON p.ID = t.trx_mysql_thread_id
                      WHERE p.COMMAND = 'Sleep' AND p.TIME >= 2 AND t.trx_rows_locked > 0")"
if [ "$idle" = "0" ]; then pass "nothing is still holding the row locks checkout needs"
else
  fail "something is still holding the row locks checkout needs"
  hints "checkout fails with ERROR 1205 — who is the waiter waiting for? (docker logs $APP)" \
        "sys.innodb_lock_waits, or performance_schema.data_lock_waits joined to threads" \
        "the blocker is idle (Command = Sleep) in a transaction: ask the owner, then KILL its connection"
fi

if sql primary -e "SET SESSION innodb_lock_wait_timeout = 5; START TRANSACTION;
                   UPDATE shop.inventory SET reserved = reserved + 1
                   WHERE product_id = 7 AND warehouse = 'TLL'; ROLLBACK;" >/dev/null 2>&1; then
  pass "a checkout-style update on shop.inventory completes within 5 seconds"
else
  fail "a checkout-style update on shop.inventory completes within 5 seconds"
fi

# --- 2. API latency ----------------------------------------------------------
echo "API latency (P2)"
read -r key rows extra <<EOF
$(sqlv primary "EXPLAIN $API_QUERY" | awk -F'\t' '{print $7, $10, ($12 == "" ? "-" : $12)}' | tr -d '\n')
EOF
if [ "$key" != "NULL" ] && [ "${rows:-999999}" -lt 20000 ]; then
  pass "the pending-orders API query no longer reads the whole table (key: $key, rows: $rows)"
  case "$extra" in *filesort*)
    hint "it still sorts: an index that also matches the ORDER BY would avoid the filesort" ;;
  esac
else
  fail "the pending-orders API query no longer reads the whole table (EXPLAIN rows: $rows)"
  hints "the API workers log their latency (docker logs $APP); which statement do they run?" \
        "performance_schema.events_statements_summary_by_digest: compare rows examined with rows sent" \
        "EXPLAIN the statement; an index on the WHERE column, then the ORDER BY column, fixes both"
fi

# --- 3. Reports replica ------------------------------------------------------
echo "Reports replica (stale data)"
threads="$(replica_threads)"
expect "replication threads on the replica (IO/SQL)" "$threads" "ON/ON"
[ "$threads" = "ON/ON" ] || hints \
  "the reports read the replica; is it applying changes?" \
  "performance_schema.replication_applier_status_by_worker names the failing transaction and error" \
  "error 1032: the row the primary updated is missing on the replica — compare the row on both servers"

if [ "$threads" = "ON/ON" ]; then
  if wait_replica_caught_up 30; then pass "the replica has applied everything the primary has"
  else fail "the replica has applied everything the primary has"; fi
fi

p="$(payments_sum primary)"; r="$(payments_sum replica)"
if [ "$p" = "$r" ]; then pass "shop.payments is identical on the primary and the replica"
else
  fail "shop.payments differs between the primary and the replica"
  hints "replication running is not the same as replication correct" \
        "skipping the failed transaction (an empty transaction with its GTID) leaves the replica wrong" \
        "repair the row on the replica from the primary's copy, with sql_log_bin = 0, then START REPLICA"
fi

now="$(replica_only_gtids)"; then_="$(saved_replica_only_gtids)"
if ! has_saved_replica_only_gtids || [ "$now" = "$then_" ]; then
  pass "no new errant transactions on the replica"
else
  fail "the replica has transactions the primary does not: $(sqlv replica "SELECT GTID_SUBTRACT('$now', '$then_')")"
  hints "a write made directly on the replica got its own GTID" \
        "if this replica is ever promoted, the other servers must fetch that GTID from it — or break" \
        "next time use SET sql_log_bin = 0 for a local repair; to clean up, commit an empty transaction with that GTID on the primary"
fi

if [ "$CHECK_FAILURES" -gt 0 ] && [ "$LEVEL" -lt 3 ]; then
  echo "Stuck? HINT_LEVEL=$((LEVEL + 1)) ./lab check 10-final-incident"
fi
check_result
