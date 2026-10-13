#!/usr/bin/env bash
# Reference fix: a functional index on the exact expression the application
# filters on. A plain index on created_at would NOT help: the optimizer cannot
# use an index on a column that is wrapped in a function.
. "$LAB_DIR/scripts/lib.sh"

sql primary -e "CREATE INDEX idx_orders_created_date ON shop.orders ((DATE(created_at)))"
echo "Created functional index idx_orders_created_date on shop.orders ((DATE(created_at)))"
