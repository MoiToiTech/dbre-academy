#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# Stop the nightly_report connection: kill it server-side, then make sure the
# client process inside the container is gone too.
for id in $(sqlv primary "SELECT PROCESSLIST_ID FROM performance_schema.threads
                          WHERE PROCESSLIST_INFO LIKE 'SELECT SLEEP(86400) AS nightly_report%'"); do
  sql primary -e "KILL $id" 2>/dev/null || true
done
# shellcheck disable=SC2016  # expands inside the container, not here
dc exec -T primary bash -c '
  if [ -f /tmp/01-architecture-tour.pid ]; then
    kill "$(cat /tmp/01-architecture-tour.pid)" 2>/dev/null || true
  fi
  rm -f /tmp/01-architecture-tour.pid /tmp/01-architecture-tour.binlog'

sql primary -e "DROP DATABASE IF EXISTS lab"
info "01-architecture-tour reset"
