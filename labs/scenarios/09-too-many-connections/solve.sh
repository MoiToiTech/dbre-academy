#!/usr/bin/env bash
# Reference fix for 09-too-many-connections. Students: try the exercise first.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-too-many-connections/common.sh"

info "Who holds the connections? (one root session, through the reserved slot)"
sql primary --table -e "
  SELECT USER, SUBSTRING_INDEX(HOST, ':', 1) AS client, COMMAND, COUNT(*) AS conns
  FROM performance_schema.processlist
  GROUP BY USER, client, COMMAND ORDER BY conns DESC"

info "Stopping the source: the invoice worker (the release is rolled back)"
docker stop -t 5 "$WORKER" >/dev/null

info "Restoring the configured limit"
sql primary -e "RESET PERSIST max_connections; SET GLOBAL max_connections = 200;"
