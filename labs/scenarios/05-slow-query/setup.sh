#!/usr/bin/env bash
# summary: Application load with one query that burns most of the server's time — find and fix it
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/05-slow-query/common.sh"

stop_workload
info "Clearing statement digest statistics so the workload starts from zero"
sql primary -e "TRUNCATE TABLE performance_schema.events_statements_summary_by_digest;
                TRUNCATE TABLE performance_schema.events_statements_histogram_by_digest;"
start_workload
info "Application workload running in container $WORKLOAD_CONTAINER (user 'app')."
echo "Users report that the back-office dashboard is slow and the database is busy."
echo "Find the statement that costs the server the most time and fix it in the"
echo "database — the application's SQL cannot be changed. Then: ./lab check 05-slow-query"
