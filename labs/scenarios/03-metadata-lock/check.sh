#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 03-metadata-lock"
blocker="$(dc exec -T primary cat /tmp/dbre-03-metadata-lock/blocker.connid 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$blocker" ]; then
  fail "scenario is not set up"
  hint "run ./lab scenario setup 03-metadata-lock first"
  check_result; exit
fi

# 1. The idle transaction that held the shared metadata lock is gone.
if [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.threads WHERE PROCESSLIST_ID = $blocker")" = "0" ]; then
  pass "the session that held the metadata lock is gone"
else
  fail "the session holding a metadata lock on shop.customers is still connected"
  hint "sys.schema_table_lock_waits: which blocking_pid is not itself waiting for anything?"
  hint "performance_schema.metadata_locks shows who holds what, GRANTED and PENDING"
fi

# 2. Nothing waits for a metadata lock any more.
waiting=1
for _ in $(seq 10); do
  waiting="$(sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist
                           WHERE STATE = 'Waiting for table metadata lock'")"
  [ "$waiting" = "0" ] && break
  sleep 0.5
done
if [ "$waiting" = "0" ]; then pass "no session is waiting for a metadata lock"
else fail "$waiting session(s) still 'Waiting for table metadata lock'"; fi

# 3. The migration completed: the column exists.
col="$(sqlv primary "SELECT COUNT(*) FROM information_schema.COLUMNS
                     WHERE TABLE_SCHEMA = 'shop' AND TABLE_NAME = 'customers'
                       AND COLUMN_NAME = 'marketing_opt_in'")"
if [ "$col" = "1" ]; then
  pass "the migration finished: shop.customers.marketing_opt_in exists"
else
  fail "the migration has not finished: shop.customers.marketing_opt_in is missing"
  hint "if you killed the ALTER, run it again yourself, guarded by a short lock_wait_timeout:"
  hint "SET SESSION lock_wait_timeout = 5; ALTER TABLE shop.customers ADD COLUMN marketing_opt_in TINYINT NOT NULL DEFAULT 0;"
fi

check_result
