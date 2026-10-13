#!/usr/bin/env bash
# Restores the baseline for 09-wont-start, solved or not. Works when the
# primary container is stopped, so it can also be run directly:
#   LAB_DIR="$PWD" bash scenarios/09-wont-start/reset.sh      (from labs/)
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-wont-start/common.sh"

# A student's rescue container must not share the data directory with the
# real primary.
docker rm -f "$RESCUE" >/dev/null 2>&1 || true

if [ "$(primary_state)" != "running" ]; then
  info "Primary is not running; removing the bad setting offline"
  dc stop -t 120 primary >/dev/null 2>&1 || true
  rescue_reset_persist lower_case_table_names
fi
start_primary

info "Clearing the scenario's persisted settings"
sql primary <<'SQL'
RESET PERSIST IF EXISTS lower_case_table_names;
RESET PERSIST IF EXISTS log_slow_extra;
SET GLOBAL log_slow_extra = OFF;
SQL

if [ "$(replica_threads)" != "ON/ON" ]; then
  sql replica -e "START REPLICA"
fi
wait_replica_caught_up 120 || die "replica did not catch up with the primary"
info "09-wont-start reset"
