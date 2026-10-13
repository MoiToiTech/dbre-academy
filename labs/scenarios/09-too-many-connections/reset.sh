#!/usr/bin/env bash
# Restores the baseline for 09-too-many-connections, solved or not.
. "$LAB_DIR/scripts/lib.sh"
# shellcheck source=common.sh
. "$LAB_DIR/scenarios/09-too-many-connections/common.sh"

stop_worker

# Wait for the server to notice the closed sockets, then clear stragglers.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist WHERE USER = 'app'")" = "0" ] && break
  sleep 1
done
kills="$(sqlv primary "SELECT CONCAT('KILL ', ID, ';') FROM performance_schema.processlist WHERE USER = 'app'")"
[ -z "$kills" ] || sql primary -e "$kills" 2>/dev/null || true

# 200 is the value in mysql/primary.cnf. Undo anything a student may have
# changed on the built-in app account while mitigating.
sql primary <<'SQL'
RESET PERSIST IF EXISTS max_connections;
SET GLOBAL max_connections = 200;
ALTER USER 'app'@'%' WITH MAX_USER_CONNECTIONS 0 ACCOUNT UNLOCK;
SQL
wait_replica_caught_up 120 || die "replica did not catch up with the primary"
info "09-too-many-connections reset"
