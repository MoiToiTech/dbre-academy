#!/usr/bin/env bash
# summary: The primary refuses connections (ERROR 1040); get in, find the source, mitigate, restore the limit
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-too-many-connections/common.sh"

# Persisted, so that a restart does not quietly "fix" it: the low limit
# comes back from mysqld-auto.cnf, as a bad SET PERSIST would in production.
info "Lowering max_connections to $LOW_LIMIT (persisted)"
sqlv primary "SET PERSIST max_connections = $LOW_LIMIT"

info "Deploying the new invoice worker"
start_worker

waited=0
# Full means every ordinary slot is taken by someone other than this script.
until [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist
                         WHERE COMMAND NOT IN ('Daemon') AND ID <> CONNECTION_ID()")" -ge "$LOW_LIMIT" ]; do
  [ "$waited" -ge 60 ] && die "the worker did not saturate max_connections within 60s"
  sleep 1; waited=$((waited + 1))
done

# Show the symptom the application sees.
if dc exec -T -e MYSQL_PWD=dbre-lab-app primary mysql -h127.0.0.1 -uapp -e "SELECT 1" >/dev/null 2>&1; then
  die "expected the app account to be refused, but it connected"
fi
echo
echo "The application cannot connect:"
dc exec -T -e MYSQL_PWD=dbre-lab-app primary mysql -h127.0.0.1 -uapp -e "SELECT 1" 2>&1 | sed 's/^/  /' || true
