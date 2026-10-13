#!/usr/bin/env bash
# summary: Hand-tuning during an incident left runtime and persisted settings that differ from the config file
. "$LAB_DIR/scripts/lib.sh"

bash "$LAB_DIR/scenarios/02-config-drift/reset.sh" >/dev/null

info "Replaying last night's incident 'tuning' on the primary"
sql primary <<'SQL'
-- Runtime only: lost on restart, but wrong until then.
SET GLOBAL long_query_time = 10;
SET GLOBAL max_connections = 20;
-- Runtime and mysqld-auto.cnf: wrong now and after every restart.
SET PERSIST innodb_flush_log_at_trx_commit = 2;
SET PERSIST sync_binlog = 0;
-- mysqld-auto.cnf only: invisible at runtime, applied at the next restart.
SET PERSIST_ONLY skip_name_resolve = OFF;
SQL

echo
echo "Scenario ready. Find every setting that no longer matches the option files"
echo "and put it back, now and for the next restart. See exercise.md; check with:"
echo "  ./lab scenario check 02-config-drift"
