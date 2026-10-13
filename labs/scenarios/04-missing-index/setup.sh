#!/usr/bin/env bash
# summary: The support dashboard's "pending orders" query scans all of shop.orders
. "$LAB_DIR/scripts/lib.sh"

# Start from the baseline schema even if a previous run was not reset.
bash "$LAB_DIR/scenarios/04-missing-index/reset.sh" >/dev/null

query="$(cat "$LAB_DIR/scenarios/04-missing-index/query.sql")"

# The dashboard polls: run the query a few times as the application account,
# so it shows up in the statement digests (sys.statements_with_full_table_scans).
for _ in 1 2 3 4 5; do
  dc exec -T -e MYSQL_PWD=dbre-lab-app primary mysql -uapp -N -e "$query" >/dev/null
done

cat <<MSG
Scenario 04-missing-index is set up.

  The support dashboard lists orders still pending since 1 December. It is
  slow, and it gets slower as shop.orders grows. Its query:

$(sed 's/^/    /' "$LAB_DIR/scenarios/04-missing-index/query.sql");

  Make it read only the rows it returns, without a sort. Change the schema,
  not the query. Then: ./lab check 04-missing-index
MSG
