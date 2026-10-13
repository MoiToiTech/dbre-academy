#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/05-slow-query/common.sh"

echo "Checking 05-slow-query"

# 1. The plan: the application's statement must be able to use an index.
plan="$(sql primary -N -B -D shop -e "EXPLAIN $OFFENDER_SQL" | awk -F'\t' '{print $5 "|" $7 "|" $10}')"
access="${plan%%|*}"; rest="${plan#*|}"; key="${rest%%|*}"; rows="${rest#*|}"
if [ "$access" != "ALL" ] && [ "$key" != "NULL" ] && [ -n "$key" ]; then
  pass "EXPLAIN of the daily-sales query uses index '$key' (type=$access, rows≈$rows)"
else
  fail "EXPLAIN of the daily-sales query: type=$access, key=$key, rows≈$rows"
  hint "find the statement with the highest SUM_TIMER_WAIT in sys.statement_analysis,"
  hint "then ask why its WHERE clause cannot use an index (module 4, and this lesson's"
  hint "section on non-sargable predicates). The application's SQL cannot be changed."
fi

# 2. The workload: measure fresh executions in performance_schema, not old totals.
if ! workload_running; then
  fail "the application workload is not running"
  hint "restart it with: ./lab scenario setup 05-slow-query (your fix is kept)"
else
  digest="$(offender_digest)"
  snap() {
    sqlv primary "SELECT CONCAT_WS(' ', IFNULL(SUM(COUNT_STAR),0), IFNULL(SUM(SUM_ROWS_EXAMINED),0),
                                       IFNULL(SUM(SUM_ERRORS),0))
                  FROM performance_schema.events_statements_summary_by_digest
                  WHERE DIGEST = '$digest'"
  }
  read -r c0 r0 e0 <<<"$(snap)"
  waited=0
  while :; do
    sleep 2; waited=$((waited + 2))
    read -r c1 r1 e1 <<<"$(snap)"
    [ $((c1 - c0)) -ge 5 ] && break
    [ "$waited" -ge 40 ] && break
  done
  n=$((c1 - c0))
  if [ "$n" -lt 1 ]; then
    fail "no new executions of the daily-sales query were recorded in ${waited}s"
    hint "is performance_schema statement digesting still enabled? (setup_consumers)"
  else
    avg=$(( (r1 - r0) / n ))
    if [ "$avg" -le 2000 ]; then
      pass "last $n executions examined $avg rows each on average (was ~200 000)"
    else
      fail "last $n executions examined $avg rows each on average"
      hint "rows_examined per call should drop from ~200 000 to a few hundred"
    fi
    expect "the application's query still succeeds (errors in the last $n calls)" "$((e1 - e0))" "0"
  fi
fi

check_result
