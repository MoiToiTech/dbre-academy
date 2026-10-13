#!/usr/bin/env bash
# Reference fix — SPOILER. Used by CI to prove the challenge is solvable.
# Finds the oldest open transaction, shows the evidence that ending it is
# safe (idle connection, nothing modified, nothing locked), then ends it.
set -euo pipefail
cd "$(dirname "$0")/.."
q() { docker compose -f docker-compose.yml exec -T db mysql -uroot -pchallenge --batch "$@" 2>/dev/null; }

echo "Oldest open transaction:"
q -t -e "SELECT t.trx_mysql_thread_id AS id, p.user, p.host, p.command, p.time AS idle_s,
                t.trx_started, t.trx_rows_modified, t.trx_rows_locked, t.trx_state
           FROM information_schema.innodb_trx t
           JOIN information_schema.processlist p ON p.id = t.trx_mysql_thread_id
          ORDER BY t.trx_started LIMIT 1"

id=$(q --skip-column-names -e "
  SELECT t.trx_mysql_thread_id
    FROM information_schema.innodb_trx t
    JOIN information_schema.processlist p ON p.id = t.trx_mysql_thread_id
   WHERE p.command = 'Sleep' AND t.trx_rows_modified = 0
   ORDER BY t.trx_started LIMIT 1")
[ -n "$id" ] || { echo "No idle transaction that modified nothing was found."; exit 1; }

echo "Ending connection $id (idle, modified nothing: rollback is instant)."
q -e "KILL $id"
