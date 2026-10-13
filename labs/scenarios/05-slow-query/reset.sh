#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/05-slow-query/common.sh"

stop_workload

# Drop every index and column on shop.orders that is not in the baseline
# dataset: a functional index, an index on created_at, a generated column.
for idx in $(sqlv primary "SELECT DISTINCT INDEX_NAME FROM information_schema.STATISTICS
                           WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders'
                             AND INDEX_NAME NOT IN ($BASELINE_INDEXES)"); do
  info "Dropping index shop.orders.$idx"
  sql primary -e "DROP INDEX \`$idx\` ON shop.orders"
done
for col in $(sqlv primary "SELECT COLUMN_NAME FROM information_schema.COLUMNS
                           WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'orders'
                             AND COLUMN_NAME NOT IN ($BASELINE_COLUMNS)"); do
  info "Dropping column shop.orders.$col"
  sql primary -e "ALTER TABLE shop.orders DROP COLUMN \`$col\`"
done

# Slow-log settings this module asks students to change, back to the lab's
# configuration (primary.cnf) and the server defaults.
sql primary -e "
  RESET PERSIST IF EXISTS long_query_time;
  RESET PERSIST IF EXISTS log_slow_extra;
  RESET PERSIST IF EXISTS log_queries_not_using_indexes;
  RESET PERSIST IF EXISTS min_examined_row_limit;
  SET GLOBAL long_query_time = 1;
  SET GLOBAL log_slow_extra = OFF;
  SET GLOBAL log_queries_not_using_indexes = OFF;
  SET GLOBAL min_examined_row_limit = 0;"
info "05-slow-query reset: workload stopped, shop.orders and slow-log settings at baseline"
