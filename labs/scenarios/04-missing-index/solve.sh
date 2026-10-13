#!/usr/bin/env bash
# Reference fix: equality column first, range (and ORDER BY) column second.
. "$LAB_DIR/scripts/lib.sh"
sql primary -e "ALTER TABLE shop.orders ADD INDEX idx_orders_status_created (status, created_at)"
