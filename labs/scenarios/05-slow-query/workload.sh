#!/usr/bin/env bash
# Application traffic for scenario 05-slow-query. Runs INSIDE a throwaway
# container on the lab network (started by setup.sh, removed by reset.sh), as
# the 'app' account, one connection per request batch like a typical web app.
#
# The SQL is the application's and cannot be changed by the student: the fix
# has to be made in the database.
#
# Deterministic: every value is derived from the loop counter.

set -u
export MYSQL_PWD=dbre-lab-app
i=0
while :; do
  i=$((i + 1))
  # Order page: primary-key lookups (frequent, cheap).
  a=$(( (i * 7919) % 200000 + 1 ))
  b=$(( (i * 104729) % 200000 + 1 ))
  # Customer's recent orders (indexed by customer_id).
  c=$(( (i * 31) % 20000 + 1 ))
  # Product availability by SKU (unique index).
  p=$(( (i * 13) % 1000 + 1 ))
  sku=$(printf 'SKU-%06d' "$p")
  # Daily sales figure for the back-office dashboard, one day per request.
  day=$(( i % 700 ))
  d=$(date -u -d "2024-01-15 +${day} days" +%F 2>/dev/null || echo 2025-03-14)

  mysql -h primary -u app -D shop --connect-timeout=5 -N -B >/dev/null 2>&1 <<SQL
SELECT id, status, total_cents FROM orders WHERE id = $a;
SELECT id, status, total_cents FROM orders WHERE id = $b;
SELECT id, created_at, status FROM orders WHERE customer_id = $c ORDER BY id DESC LIMIT 10;
SELECT i.warehouse, i.on_hand FROM inventory i JOIN products p ON p.id = i.product_id WHERE p.sku = '$sku';
SELECT COUNT(*), SUM(total_cents) FROM orders WHERE DATE(created_at) = '$d';
SQL
  sleep 0.2
done
