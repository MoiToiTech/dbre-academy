#!/usr/bin/env bash
# Reference fix: the root blocker is the session that blocks others but is not
# itself waiting. End it; the queued ALTER and the reads then complete.
. "$LAB_DIR/scripts/lib.sh"

pid="$(sqlv primary "
  SELECT DISTINCT blocking_pid FROM sys.schema_table_lock_waits
   WHERE object_schema = 'shop' AND object_name = 'customers'
     AND blocking_pid NOT IN (SELECT waiting_pid FROM sys.schema_table_lock_waits)")"
[ -n "$pid" ] || die "no metadata lock waits found — is the scenario set up?"
[ "$(printf '%s\n' "$pid" | wc -l | tr -d ' ')" = "1" ] || die "expected one root blocker, found: $pid"
echo "Root blocker: $pid"
sql primary -e "KILL $pid"
