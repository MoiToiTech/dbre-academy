#!/usr/bin/env bash
# Restores the baseline for 10-final-incident, solved or not.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/10-final-incident/common.sh"

info "Stopping the scenario's application containers"
docker rm -f "$APP" "$CONSOLE" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist
                     WHERE USER IN ('app', 'backoffice')")" = "0" ] && break
  sleep 1
done
kills="$(sqlv primary "SELECT CONCAT('KILL ', ID, ';') FROM performance_schema.processlist
                       WHERE USER IN ('app', 'backoffice')")"
[ -z "$kills" ] || sql primary -e "$kills" 2>/dev/null || true

info "Repairing the replica if needed"
missing="$(sqlv replica "SELECT COUNT(*) = 0 FROM shop.payments WHERE id = $PAYMENT_ID")"
if [ "$(replica_threads)" != "ON/ON" ] || [ "$missing" = "1" ]; then
  sql replica -e "STOP REPLICA"
  # The values are the dataset's own; later primary events overwrite status.
  sql replica <<SQL
SET SESSION sql_log_bin = 0;
SET GLOBAL super_read_only = OFF;
INSERT IGNORE INTO shop.payments (id, order_id, method, amount_cents, status, created_at)
SELECT $PAYMENT_ID, 4391, 'bank_transfer', 72379, 'captured', '2024-01-17 00:15:41';
SET GLOBAL super_read_only = ON;
START REPLICA;
SQL
fi

info "Restoring the primary's data and schema"
extra_idx="$(sqlv primary "SELECT GROUP_CONCAT(DISTINCT CONCAT('DROP INDEX ', INDEX_NAME))
                           FROM information_schema.statistics
                           WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders'
                             AND INDEX_NAME NOT IN ('PRIMARY', 'idx_orders_customer')")"
if [ "$extra_idx" != "NULL" ]; then sqlv primary "ALTER TABLE shop.orders $extra_idx"; fi
sql primary <<SQL
UPDATE shop.payments SET status = 'captured' WHERE id = $PAYMENT_ID AND status <> 'captured';
DROP USER IF EXISTS 'backoffice'@'%';
SQL
wait_replica_caught_up 120 || die "replica did not catch up with the primary"

# Errant transactions a student may have created on the replica: drop them
# from its GTID history so the lab's baseline stays failover-safe.
if has_saved_replica_only_gtids; then
  saved="$(saved_replica_only_gtids)"
  extra="$(sqlv replica "SELECT GTID_SUBTRACT('$(replica_only_gtids)', '$saved')" | tr -d '\n')"
  if [ -n "$extra" ]; then
    warn "removing errant GTIDs from the replica: $extra"
    keep="$(sqlv replica "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$extra')" | tr -d '\n')"
    sql replica <<SQL
STOP REPLICA;
RESET BINARY LOGS AND GTIDS;
SET GLOBAL gtid_purged = '$keep';
START REPLICA;
SQL
  fi
  dc exec -T replica rm -f "$STATE_FILE"
fi
# As ./lab up leaves it, in case super_read_only was switched off by hand.
sql replica -e "SET PERSIST read_only = ON; SET PERSIST super_read_only = ON;"
wait_replica_caught_up 120 || die "replica did not catch up with the primary"
info "10-final-incident reset"
