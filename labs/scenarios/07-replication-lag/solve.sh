#!/usr/bin/env bash
# Reference fix: the applier waits for the global read lock that a hung
# backup session on the replica holds. Find the session that owns the lock
# and end it; the applier then catches up on its own.
. "$LAB_DIR/scripts/lib.sh"

pid="$(sqlv replica "
  SELECT DISTINCT t.PROCESSLIST_ID
    FROM performance_schema.metadata_locks m
    JOIN performance_schema.threads t ON t.THREAD_ID = m.OWNER_THREAD_ID
   WHERE m.OBJECT_TYPE = 'GLOBAL' AND m.LOCK_TYPE = 'SHARED' AND m.LOCK_STATUS = 'GRANTED'")"
[ -n "$pid" ] || die "no session holds the global read lock — is the scenario set up?"
echo "global read lock held by connection $pid"
sql replica -e "KILL $pid"
wait_replica_caught_up 120 || die "replica did not catch up"
