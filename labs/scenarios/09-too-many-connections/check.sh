#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-too-many-connections/common.sh"

echo "Checking 09-too-many-connections"

# The check itself needs a connection. While the server is saturated, root
# only gets in through the single reserved CONNECTION_ADMIN slot.
if ! out="$(sqlv primary "SELECT 1" 2>&1)"; then
  fail "root can connect to the primary"
  case "$out" in
    *1040*) hint "only one extra connection is reserved for CONNECTION_ADMIN — close any other root session and retry" ;;
    *) hint "$out" ;;
  esac
  check_result; exit 1
fi

runtime="$(sqlv primary "SELECT @@GLOBAL.max_connections")"
if [ "$runtime" -ge "$SANE_LIMIT" ]; then pass "max_connections is $runtime (at least $SANE_LIMIT)"
else
  fail "max_connections is $runtime (expected at least $SANE_LIMIT)"
  hint "compare SHOW GLOBAL VARIABLES LIKE 'max_connections' with the server's configuration file"
fi

persisted="$(sqlv primary "SELECT IFNULL(MAX(VARIABLE_VALUE), 'none') FROM performance_schema.persisted_variables
                           WHERE VARIABLE_NAME = 'max_connections'")"
if [ "$persisted" = "none" ] || [ "$persisted" -ge "$SANE_LIMIT" ]; then
  pass "no low max_connections will come back at the next restart (persisted: $persisted)"
else
  fail "a restart would bring back max_connections = $persisted"
  hint "SET GLOBAL lasts until restart; look in performance_schema.persisted_variables"
fi

held="$(worker_connections)"
if [ "$held" = "0" ]; then pass "the source of the idle connections no longer holds any"
else
  fail "one client still holds $held idle app connections"
  hint "group the processlist by user and client address; KILL alone will not last if the client reconnects"
fi

if dc exec -T -e MYSQL_PWD=dbre-lab-app primary mysql -h127.0.0.1 -uapp -e "SELECT 1" >/dev/null 2>&1; then
  pass "the application account can connect"
else
  fail "the application account can connect"
  hint "new app connections are refused: is a slot free, and is the account usable? (SHOW CREATE USER 'app'@'%')"
fi

check_result
