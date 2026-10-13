#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 07-broken-replication"
before="$(dc exec -T primary cat /backups/07-broken-replication/.errant-before 2>/dev/null)" || {
  fail "scenario is not set up"
  hint "run ./lab scenario setup 07-broken-replication first"
  check_result; exit
}
FP_SQL="$LAB_DIR/datasets/shop/fingerprint.sql"

# 1. Both replication threads run and no worker reports an error.
state="$(sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                       FROM performance_schema.replication_connection_status c
                       JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)")"
errs="$(sqlv replica "SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker
                      WHERE LAST_ERROR_NUMBER <> 0")"
if [ "$state" = "ON/ON" ] && [ "$errs" = "0" ]; then
  pass "receiver and applier threads are running without errors"
else
  fail "replication is not running cleanly (receiver/applier: $state, workers with errors: $errs)"
  hint "performance_schema.replication_applier_status_by_worker has the full error per worker"
fi

# 2. The replica has applied everything the primary has.
if [ "$state" = "ON/ON" ] && [ "$errs" = "0" ] && wait_replica_caught_up 60; then
  pass "the replica has executed every transaction the primary has"
else
  fail "the replica is missing transactions the primary has executed"
fi

# 3. No errant transactions: nothing on the replica the primary lacks.
pg="$(sqlv primary 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
errant="$(sqlv replica "SELECT GTID_SUBTRACT(GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$pg'), '$before')" | tr -d '\n')"
if [ -z "$errant" ]; then
  pass "no errant transactions on the replica"
else
  fail "errant transactions on the replica: $errant"
  hint "the replica executed these, the primary never did; a failover would ship them to every other replica"
  hint "once their effect on the data is dealt with, make the primary know them (empty transactions)"
fi

# 4. Same data on both servers.
p="$(sql primary -N -B < "$FP_SQL")"; r="$(sql replica -N -B < "$FP_SQL")"
if [ "$p" = "$r" ]; then
  pass "shop has identical content on primary and replica"
else
  fail "shop differs between primary and replica"
  diff <(printf '%s\n' "$p") <(printf '%s\n' "$r") | sed -n 's/^/       /p' | head -10 || true
  hint "skipping a failing transaction makes replication run, not the data right"
  hint "compare the conflicting rows on both servers; the primary is the source of truth"
fi

# 5. The replica's write protection is back.
expect "replica super_read_only is ON" "$(sqlv replica 'SELECT @@GLOBAL.super_read_only')" "1"

check_result
