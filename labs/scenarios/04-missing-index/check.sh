#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 04-missing-index"
query="$(cat "$LAB_DIR/scenarios/04-missing-index/query.sql")"
# Optimizer estimates from EXPLAIN FORMAT=JSON. The query returns 238 rows.
plan="$(sqlv primary "
  EXPLAIN FORMAT=JSON INTO @j $query;
  SELECT CONCAT_WS('|',
    JSON_UNQUOTE(JSON_EXTRACT(JSON_EXTRACT(@j, '\$**.access_type'), '\$[0]')),
    IFNULL(JSON_UNQUOTE(JSON_EXTRACT(JSON_EXTRACT(@j, '\$**.key'), '\$[0]')), 'NULL'),
    JSON_EXTRACT(JSON_EXTRACT(@j, '\$**.rows_examined_per_scan'), '\$[0]'),
    IFNULL(JSON_EXTRACT(JSON_EXTRACT(@j, '\$**.used_key_parts'), '\$[0]'), '[]'),
    IFNULL(JSON_EXTRACT(JSON_EXTRACT(@j, '\$**.using_filesort'), '\$[0]'), 'false'))")"
IFS='|' read -r access key rows parts filesort <<<"$plan"
echo "  plan: access=$access key=$key rows=$rows used_key_parts=$parts filesort=$filesort"

if [ "$key" != "NULL" ]; then pass "the query uses an index ($key)"
else
  fail "the query does not use an index (access type $access)"
  hint "EXPLAIN the query: which columns does the WHERE clause filter on?"
fi

if [ "$rows" -le 500 ]; then pass "the plan examines $rows rows (limit 500)"
else
  fail "the plan examines $rows rows to return 238 (limit 500)"
  if [ "$key" != "NULL" ]; then
    hint "the index narrows the scan, but InnoDB still reads rows it then throws away"
    hint "compare rows with the 238 the query returns: which condition is not served by the index?"
  fi
fi

case "$parts" in
  *status*created_at*) pass "the index serves both the status equality and the created_at range" ;;
  *) fail "the index does not serve both conditions (used_key_parts: $parts)"
     hint "column order matters: equality columns first, the range column last" ;;
esac

if [ "$filesort" = "false" ]; then pass "no filesort: rows come out of the index in ORDER BY order"
else fail "the plan still sorts the result (Using filesort)"; fi

check_result
