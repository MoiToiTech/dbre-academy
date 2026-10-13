#!/usr/bin/env bash
# summary: A persisted setting stops the primary from starting; find it in the error log and recover
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-wont-start/common.sh"

# Two persisted settings: one legitimate (it must survive the repair), one
# that the data dictionary will reject at the next start.
info "Persisting settings on the primary"
sql primary <<'SQL'
SET PERSIST log_slow_extra = ON;
SET PERSIST_ONLY lower_case_table_names = 1;
SQL

# A clean shutdown first: Compose's default 10-second stop timeout can
# SIGKILL mysqld mid-shutdown, and this scenario is about the next start,
# not about crash recovery.
info "Restarting the primary (planned maintenance window)"
dc stop -t 120 primary >/dev/null 2>&1
dc start primary >/dev/null 2>&1 || true

if ! wait_exited 120; then
  die "expected the primary to fail to start, but it is $(primary_state)"
fi
echo
echo "The primary did not come back after the restart (container: exited)."
echo "Start with: ./lab logs primary"
