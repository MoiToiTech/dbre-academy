#!/usr/bin/env bash
# summary: Final challenge — checkout errors, a slow API and stale reports at once; triage, mitigate, fix
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/10-final-incident/common.sh"

wait_replica_caught_up 120 || die "the replica is behind before the scenario starts — run ./lab status"
[ "$(replica_threads)" = "ON/ON" ] || die "replication is not running — run ./lab scenario reset 10-final-incident"

# Remember which GTIDs only the replica has, so that check.sh can tell new
# errant transactions from the ones the lab started with.
replica_only_gtids | dc exec -T replica sh -c "cat > $STATE_FILE"

info "Preparing the incident"
sql primary <<'SQL'
CREATE USER IF NOT EXISTS 'backoffice'@'%' IDENTIFIED BY 'dbre-lab-backoffice';
GRANT SELECT ON shop.* TO 'backoffice'@'%';
GRANT UPDATE ON shop.inventory TO 'backoffice'@'%';
SQL
wait_replica_caught_up 60 || die "replica did not apply the account"

# Fault 3: a "clean-up" run against the wrong host deletes a payment on the
# replica only (sql_log_bin = 0, so it leaves no GTID behind) ...
sql replica <<SQL
SET SESSION sql_log_bin = 0;
SET GLOBAL super_read_only = OFF;
DELETE FROM shop.payments WHERE id = $PAYMENT_ID;
SET GLOBAL super_read_only = ON;
SQL
# ... and support then refunds that payment on the primary.
sqlv primary "UPDATE shop.payments SET status = 'refunded' WHERE id = $PAYMENT_ID"

# Fault 1: an uncommitted stock correction.
start_console
console_started=$SECONDS
waited=0
until [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.innodb_trx t
                         JOIN performance_schema.processlist p ON p.ID = t.trx_mysql_thread_id
                         WHERE p.USER = 'backoffice' AND t.trx_rows_locked > 0")" = "1" ]; do
  [ "$waited" -ge 30 ] && die "the back-office transaction did not start"
  sleep 1; waited=$((waited + 1))
done

# Fault 2 arrives with the application's new release.
start_app

# Wait until the symptoms are real: checkout blocked on a lock, the replica
# applier stopped.
waited=0
until [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.data_lock_waits")" -gt 0 ] \
   && [ "$(replica_threads)" = "ON/OFF" ]; do
  [ "$waited" -ge 60 ] && die "the incident did not develop within 60s"
  sleep 1; waited=$((waited + 1))
done
# Let the incident run for a few seconds before handing over.
while [ $((SECONDS - console_started)) -lt 8 ]; do sleep 1; done

cat <<'EOF'

PAGER  [P1] shop-checkout: error rate 100% over 5 min (threshold 2%)
PAGER  [P2] api-orders: p95 latency above SLO since the 10:30 release
TICKET support: "Reports still show order 4391 as paid, refunded an hour ago"

You are the on-call DBRE. The brief is in
courses/mysql-production-dba/10-final-challenge/README.md
EOF
