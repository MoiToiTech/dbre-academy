#!/usr/bin/env bash
# Lock pile-up for scenario 08-saturation-alert. Runs INSIDE a throwaway
# container on the lab network (started by setup.sh, removed by reset.sh).
#
# One 'app' session takes a row lock on an inventory row and then idles
# inside its transaction (a request handler that hangs before COMMIT).
# Sixteen more sessions keep trying to lock the same row: each waits
# innodb_lock_wait_timeout (20 s in the lab), fails with error 1205 and
# retries, as a naive application would.
#
# Nothing is modified: every statement is a locking read, so the dataset is
# untouched whatever happens. The literal 'dbre-08-pileup' tags the sessions
# so that reset.sh can find and kill them.

set -u
export MYSQL_PWD=dbre-lab-app
ROW="product_id = 42 AND warehouse = 'TLL'"

mysql -h primary -u app -D shop -N -B >/dev/null 2>&1 <<SQL &
BEGIN;
SELECT on_hand, 'dbre-08-pileup' FROM inventory WHERE $ROW FOR UPDATE;
DO SLEEP(86400), 'dbre-08-pileup';
SQL

sleep 1
for w in $(seq 1 16); do
  (
    while :; do
      mysql -h primary -u app -D shop -N -B -e \
        "SELECT on_hand, 'dbre-08-pileup' FROM inventory WHERE $ROW FOR UPDATE" \
        >/dev/null 2>&1
      sleep "0.$w"
    done
  ) &
done
wait
