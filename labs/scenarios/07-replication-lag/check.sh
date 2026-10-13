#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 07-replication-lag"
if [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.TABLES
                      WHERE TABLE_SCHEMA = 'lab' AND TABLE_NAME = 'heartbeat'")" != "1" ]; then
  fail "scenario is not set up"
  hint "run ./lab scenario setup 07-replication-lag first"
  check_result; exit
fi

# 1. The cause is gone: nobody holds the global read lock on the replica.
held="$(sqlv replica "SELECT COUNT(*) FROM performance_schema.metadata_locks
                      WHERE OBJECT_TYPE IN ('GLOBAL', 'COMMIT') AND LOCK_TYPE = 'SHARED'
                        AND LOCK_STATUS = 'GRANTED'")"
if [ "$held" = "0" ]; then
  pass "no session holds a global read lock on the replica"
else
  fail "a session on the replica still holds a global read lock"
  hint "what are the applier workers waiting for? SHOW PROCESSLIST on the replica"
  hint "performance_schema.metadata_locks: OBJECT_TYPE GLOBAL/COMMIT, who holds them (OWNER_THREAD_ID)?"
  hint "KILL QUERY ends a statement, not a session: a lock taken earlier in the session survives it"
fi

# 2. Both replication threads are running.
state="$(sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                       FROM performance_schema.replication_connection_status c
                       JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)")"
expect "receiver/applier threads running" "$state" "ON/ON"

# 3. Lag is back to zero: by GTID set and by the heartbeat.
if [ "$held" = "0" ] && [ "$state" = "ON/ON" ] && wait_replica_caught_up 60; then
  pass "the replica has executed every transaction the primary has"
else
  fail "the replica is still behind the primary (GTID sets differ)"
fi
lag="$(sqlv replica "SELECT ROUND(TIMESTAMPDIFF(MICROSECOND, ts, NOW(6)) / 1e6, 1)
                     FROM lab.heartbeat WHERE id = 1" 2>/dev/null || echo unknown)"
if [ "$lag" != "unknown" ] && awk -v l="$lag" 'BEGIN { exit !(l < 5) }'; then
  pass "heartbeat delay on the replica is ${lag}s"
else
  fail "heartbeat delay on the replica is ${lag}s (want under 5s)"
  if [ "$lag" = "unknown" ]; then
    hint "lab.heartbeat is missing on the replica — run ./lab scenario reset 07-replication-lag, then setup"
  fi
fi

# 4. And the data agrees.
FP_SQL="$LAB_DIR/datasets/shop/fingerprint.sql"
if [ "$(sql primary -N -B < "$FP_SQL")" = "$(sql replica -N -B < "$FP_SQL")" ]; then
  pass "shop has identical content on primary and replica"
else
  fail "shop differs between primary and replica"
fi

check_result
