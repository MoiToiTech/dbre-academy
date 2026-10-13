#!/usr/bin/env bash
# Reference fix for 10-final-incident. Students: try the challenge first.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/10-final-incident/common.sh"

info "1. Checkout: kill the idle transaction that blocks it"
sql primary --table -e "SELECT waiting_pid, blocking_pid, wait_age_secs, sql_kill_blocking_connection
                        FROM sys.innodb_lock_waits"
# The blocker is idle inside a transaction that holds row locks.
blocker="$(sqlv primary "SELECT p.ID FROM information_schema.innodb_trx t
                         JOIN performance_schema.processlist p ON p.ID = t.trx_mysql_thread_id
                         WHERE p.COMMAND = 'Sleep' AND t.trx_rows_locked > 0
                         ORDER BY t.trx_started LIMIT 1")"
[ -n "$blocker" ] || die "no idle transaction holding locks found"
sqlv primary "KILL $blocker"

info "2. API: index for the pending-orders query (WHERE column, then ORDER BY column)"
sqlv primary "ALTER TABLE shop.orders ADD INDEX idx_orders_status_created (status, created_at),
              ALGORITHM = INPLACE, LOCK = NONE"

info "3. Replica: restore the missing row from the primary, then resume"
sql replica --table -e "SELECT LAST_ERROR_NUMBER, APPLYING_TRANSACTION
                        FROM performance_schema.replication_applier_status_by_worker
                        WHERE LAST_ERROR_NUMBER <> 0"
row="$(sqlv primary "SELECT CONCAT_WS(',', id, order_id, QUOTE(method), amount_cents,
                                       QUOTE(status), QUOTE(created_at))
                     FROM shop.payments WHERE id = $PAYMENT_ID")"
sql replica <<SQL
SET SESSION sql_log_bin = 0;
SET GLOBAL super_read_only = OFF;
INSERT INTO shop.payments (id, order_id, method, amount_cents, status, created_at) VALUES ($row);
SET GLOBAL super_read_only = ON;
START REPLICA;
SQL
wait_replica_caught_up 120 || die "replica did not catch up"
