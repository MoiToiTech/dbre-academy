#!/usr/bin/env bash
# Runs INSIDE the primary container (started by setup.sh with docker compose
# exec -d), so the sessions outlive setup.sh. Not for students to run.
#
#   session.sh report      open a transaction, read shop.customers, go idle
#   session.sh migration   the deploy's ALTER TABLE shop.customers
#   session.sh api <n>     an API request reading one customer
#
# Every process writes its pid to $RUN_DIR; reset.sh kills them from there.
set -u
RUN_DIR=/tmp/dbre-03-metadata-lock
mkdir -p "$RUN_DIR"
MARK="SET @dbre_scenario='03-metadata-lock'"

case "${1:-}" in
  report)
    # A reporting job opened a transaction, ran one query and never committed.
    export MYSQL_PWD=dbre-lab-app
    coproc REPORT { exec mysql -uapp -N --init-command="$MARK" shop >/dev/null 2>&1; }
    echo "$REPORT_PID" > "$RUN_DIR/report-client.pid"
    echo "$$" > "$RUN_DIR/report.pid"
    trap 'kill "$REPORT_PID" 2>/dev/null; wait "$REPORT_PID"; exit 0' TERM INT
    printf '%s\n' \
      "START TRANSACTION;" \
      "SELECT country_code, COUNT(*) FROM customers GROUP BY country_code;" \
      >&"${REPORT[1]}"
    wait "$REPORT_PID"
    ;;
  migration)
    # The deploy pipeline's schema change, run with the server defaults.
    export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
    echo "$$" > "$RUN_DIR/migration.pid"
    mysql -uroot --init-command="$MARK" shop -e \
      "ALTER TABLE customers ADD COLUMN marketing_opt_in TINYINT NOT NULL DEFAULT 0" \
      >"$RUN_DIR/migration.log" 2>&1 &
    client=$!
    echo "$client" > "$RUN_DIR/migration-client.pid"
    trap 'kill "$client" 2>/dev/null; wait "$client"; exit 0' TERM INT
    wait "$client"
    echo "exit=$?" >> "$RUN_DIR/migration.log"
    ;;
  api)
    export MYSQL_PWD=dbre-lab-app
    echo "$$" > "$RUN_DIR/api-${2:?n}.pid"
    mysql -uapp -N --init-command="$MARK" shop -e \
      "SELECT id, email, status FROM customers WHERE id = ${2}" >/dev/null 2>&1 &
    client=$!
    echo "$client" > "$RUN_DIR/api-$2-client.pid"
    trap 'kill "$client" 2>/dev/null; wait "$client"; exit 0' TERM INT
    wait "$client"
    ;;
  *) echo "usage: $0 report | migration | api <n>" >&2; exit 2 ;;
esac
