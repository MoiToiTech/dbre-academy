#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 06-pitr"
expected="$(dc exec -T primary cat /backups/pitr/.expected-fingerprint 2>/dev/null || true)"
if [ -z "$expected" ]; then
  fail "scenario is not set up"
  hint "run ./lab scenario setup 06-pitr first"
  check_result; exit
fi
FP_SQL="$LAB_DIR/datasets/shop/fingerprint.sql"

# 1. Replication is running and the replica has everything the primary has.
state="$(sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                       FROM performance_schema.replication_connection_status c
                       JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)")"
if [ "$state" = "ON/ON" ] && wait_replica_caught_up 60; then
  pass "replication is running and the replica has caught up"
else
  fail "replication is not healthy (receiver/applier: $state) or the replica is behind"
  hint "./lab status; on the replica: SHOW REPLICA STATUS\\G — look at Last_SQL_Error"
  hint "did you load the backup with binary logging off on the primary? Then the replica never saw it"
fi

# 2. The primary holds the data as it would be without the accident.
compare() { # compare <server>
  local actual
  actual="$(sql "$1" -N -B < "$FP_SQL")"
  if [ "$actual" = "$expected" ]; then
    pass "$1: shop matches the expected fingerprint"
  else
    fail "$1: shop differs from the expected state"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed -n 's/^/       /p' | head -14 || true
    if [ "$1" = primary ]; then
      local want got
      want="$(printf '%s\n' "$expected" | awk '$1 == "payments" {print $2}')"
      got="$(printf '%s\n' "$actual" | awk '$1 == "payments" {print $2}')"; got="${got:-0}"
      if [ "$got" -lt "$want" ]; then
        hint "payments are missing: the failed payments, or the ones written after the backup"
        hint "if a replay changed nothing: those GTIDs are already executed here (--skip-gtids)"
      elif [ "$got" -gt "$want" ]; then
        hint "more payments than expected: something was applied twice (the restore inside the replay window?)"
      else
        hint "right row counts, wrong checksums: a replay was partial, or rows from the backup were mixed in"
      fi
    fi
  fi
}
compare primary
compare replica

check_result
