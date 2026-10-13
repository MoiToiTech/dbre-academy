#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-wont-start/common.sh"

echo "Checking 09-wont-start"

state="$(primary_state)"
if [ "$state" != "running" ] || ! sqlv primary "SELECT 1" >/dev/null 2>&1; then
  fail "the primary is up and accepts connections (container: $state)"
  hint "read why mysqld stopped: ./lab logs primary (look for [ERROR] lines)"
  check_result; exit 1
fi
pass "the primary is up and accepts connections"

if docker ps -q --filter "name=^${RESCUE}$" | grep -q .; then
  fail "the rescue container $RESCUE has been removed"
  hint "two mysqld processes must never share one data directory: docker rm -f $RESCUE"
fi

bad="$(sqlv primary "SELECT COUNT(*) FROM performance_schema.persisted_variables
                     WHERE VARIABLE_NAME = 'lower_case_table_names'")"
expect "lower_case_table_names is no longer persisted in mysqld-auto.cnf" "$bad" "0"
[ "$bad" = "0" ] || hint "a persisted value is applied again at every start: RESET PERSIST ..."

kept="$(sqlv primary "SELECT IFNULL(MAX(VARIABLE_VALUE), 'missing') FROM performance_schema.persisted_variables
                      WHERE VARIABLE_NAME = 'log_slow_extra'")"
expect "the legitimate persisted setting log_slow_extra is still persisted" "$kept" "ON"
[ "$kept" = "ON" ] || hint "remove only the bad entry; deleting mysqld-auto.cnf also loses good settings"

orders="$(sqlv primary "SELECT COUNT(*) FROM shop.orders" 2>/dev/null || echo 0)"
expect "the primary kept its data (shop.orders rows)" "$orders" "200000"

threads="$(replica_threads 2>/dev/null || echo unknown)"
expect "replication threads on the replica (IO/SQL)" "$threads" "ON/ON"
[ "$threads" = "ON/ON" ] || hint "the replica stops retrying after SOURCE_RETRY_COUNT attempts — see SHOW REPLICA STATUS on the replica"

if [ "$threads" = "ON/ON" ]; then
  if wait_replica_caught_up 30; then pass "the replica has caught up with the primary"
  else fail "the replica has caught up with the primary"; fi
fi

check_result
