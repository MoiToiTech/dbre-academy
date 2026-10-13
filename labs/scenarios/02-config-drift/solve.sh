#!/usr/bin/env bash
# Reference solution. Try the exercise first.
. "$LAB_DIR/scripts/lib.sh"

# 1. Remove the persisted settings so the next restart uses the option files.
# 2. Put the runtime values back to what the option files say (not DEFAULT).
sql primary <<'SQL'
RESET PERSIST innodb_flush_log_at_trx_commit;
RESET PERSIST sync_binlog;
RESET PERSIST skip_name_resolve;
SET GLOBAL long_query_time = 1;
SET GLOBAL max_connections = 200;
SET GLOBAL innodb_flush_log_at_trx_commit = 1;
SET GLOBAL sync_binlog = 1;
SQL
