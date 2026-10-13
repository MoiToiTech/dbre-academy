#!/usr/bin/env bash
# Restores shop.orders to the baseline schema: PRIMARY plus a visible
# idx_orders_customer (customer_id), no other indexes, no histograms.
# idx_orders_customer backs fk_orders_customer, so it is put right first:
# InnoDB refuses to drop the last index a foreign key can use.
. "$LAB_DIR/scripts/lib.sh"

idx_def() { # idx_def <index> -> "col:visible,col:visible" or empty
  sqlv primary "SELECT GROUP_CONCAT(CONCAT(COLUMN_NAME, ':', IFNULL(COLLATION, ''), ':', IS_VISIBLE)
                       ORDER BY SEQ_IN_INDEX)
                  FROM information_schema.STATISTICS
                 WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders' AND INDEX_NAME = '$1'"
}

def="$(idx_def idx_orders_customer)"
if [ "$def" != "customer_id:A:YES" ]; then
  if [ -n "$def" ]; then
    # Wrong shape or invisible: rebuild it, with a stand-in index for the FK.
    sql primary -e "ALTER TABLE shop.orders ADD INDEX dbre_tmp_fk (customer_id)"
    sql primary -e "ALTER TABLE shop.orders DROP INDEX idx_orders_customer"
  fi
  sql primary -e "ALTER TABLE shop.orders ADD INDEX idx_orders_customer (customer_id)"
fi

for idx in $(sqlv primary "SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS
                            WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders'
                              AND INDEX_NAME NOT IN ('PRIMARY', 'idx_orders_customer')"); do
  sql primary -e "ALTER TABLE shop.orders DROP INDEX \`$idx\`"
done

for col in $(sqlv primary "SELECT COLUMN_NAME FROM information_schema.COLUMN_STATISTICS
                            WHERE SCHEMA_NAME = 'shop' AND TABLE_NAME = 'orders'"); do
  sql primary -e "ANALYZE TABLE shop.orders DROP HISTOGRAM ON \`$col\`" >/dev/null
done

sql primary -e "ANALYZE TABLE shop.orders" >/dev/null
wait_replica_caught_up 120 || warn "replica is behind the primary — run ./lab status"
echo "04-missing-index reset."
