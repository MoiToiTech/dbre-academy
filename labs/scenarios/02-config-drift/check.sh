#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 02-config-drift"

# Expected values are those in the option file mysql/primary.cnf, mounted in
# the container as /etc/mysql/conf.d/dbre.cnf (see: my_print_defaults mysqld).
runtime() { sqlv primary "SELECT @@GLOBAL.$1"; }

got="$(runtime long_query_time)"
expect "long_query_time matches the option file (1)" "$got" "1.000000"
[ "$got" = "10.000000" ] && hint "10 is the compiled-in default: SET GLOBAL ... = DEFAULT does not mean 'the config file value'"
expect "max_connections matches the option file (200)" "$(runtime max_connections)" "200"
expect "innodb_flush_log_at_trx_commit matches the option file (1)" "$(runtime innodb_flush_log_at_trx_commit)" "1"
expect "sync_binlog matches the option file (1)" "$(runtime sync_binlog)" "1"
expect "skip_name_resolve is ON" "$(runtime skip_name_resolve)" "1"

# Nothing pending in mysqld-auto.cnf that would undo the option file at the
# next restart.
pending="$(sqlv primary "SELECT GROUP_CONCAT(CONCAT(VARIABLE_NAME, '=', VARIABLE_VALUE) ORDER BY VARIABLE_NAME)
                         FROM performance_schema.persisted_variables
                         WHERE VARIABLE_NAME IN ('long_query_time', 'max_connections',
                               'innodb_flush_log_at_trx_commit', 'sync_binlog', 'skip_name_resolve')")"
if [ "$pending" = "NULL" ] || [ -z "$pending" ]; then
  pass "no drifted settings left in mysqld-auto.cnf"
else
  fail "mysqld-auto.cnf still persists: $pending"
  hint "these apply at the next restart; performance_schema.persisted_variables lists them, RESET PERSIST removes them"
fi

check_result
