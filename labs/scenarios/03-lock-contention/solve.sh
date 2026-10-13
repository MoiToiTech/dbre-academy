#!/usr/bin/env bash
# Reference fix: follow the wait graph to the blocker and end its connection.
. "$LAB_DIR/scripts/lib.sh"

pid="$(sqlv primary "SELECT DISTINCT blocking_pid FROM sys.innodb_lock_waits
                     WHERE locked_table = '\`shop\`.\`inventory\`'")"
[ -n "$pid" ] || die "no lock waits found — is the scenario set up?"
[ "$(printf '%s\n' "$pid" | wc -l | tr -d ' ')" = "1" ] || die "expected one blocker, found: $pid"
echo "Blocking connection: $pid"
sql primary -e "KILL $pid"
