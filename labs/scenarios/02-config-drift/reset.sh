#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# Remove the persisted entries, then restore the values from
# mysql/primary.cnf. RESET PERSIST alone does not change runtime values.
sql primary <<'SQL'
RESET PERSIST IF EXISTS long_query_time;
RESET PERSIST IF EXISTS max_connections;
RESET PERSIST IF EXISTS innodb_flush_log_at_trx_commit;
RESET PERSIST IF EXISTS sync_binlog;
RESET PERSIST IF EXISTS skip_name_resolve;
SET GLOBAL long_query_time = 1,
           max_connections = 200,
           innodb_flush_log_at_trx_commit = 1,
           sync_binlog = 1;
SQL
info "02-config-drift reset"
