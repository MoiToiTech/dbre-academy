#!/usr/bin/env bash
# Reference fix for 09-wont-start. Students: try the exercise first.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-wont-start/common.sh"

info "Reading the error log"
dc logs --no-log-prefix --tail 200 primary 2>&1 | grep -E '\[ERROR\]' || true

info "Removing the bad persisted setting with an isolated rescue instance"
rescue_reset_persist lower_case_table_names

info "Starting the primary"
start_primary

info "Restarting replication if the replica gave up retrying"
sql replica -e "START REPLICA" 2>/dev/null || true
wait_replica_caught_up 120 || die "replica did not catch up"
