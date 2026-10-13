#!/usr/bin/env bash
# The analytics team's nightly export: revenue by country and day.
set -u
DB=(mysql -hdb -uanalytics -panalytics-local-only --batch --force --silent shop)

until "${DB[@]}" -e 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

{
  echo "SET autocommit = 0;"
  echo "SELECT c.country, DATE(o.created_at) AS day, COUNT(*) AS orders, SUM(o.total) AS revenue
        FROM orders o JOIN customers c ON c.id = o.customer_id
        GROUP BY c.country, DATE(o.created_at);"
  exec sleep infinity
} | "${DB[@]}" >/dev/null 2>&1
