#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 01-architecture-tour"
if [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.tables
                      WHERE table_schema = 'lab' AND table_name = 'answers'")" != "1" ]; then
  fail "lab.answers does not exist"
  hint "run: ./lab scenario setup 01-architecture-tour"
  check_result; exit
fi

answer() {
  sqlv primary "SELECT IFNULL(TRIM(answer), '') FROM lab.answers WHERE question = '$1'"
}

# 1. Connection -> OS thread ------------------------------------------------
live="$(sqlv primary "SELECT THREAD_OS_ID FROM performance_schema.threads
                      WHERE PROCESSLIST_INFO LIKE 'SELECT SLEEP(86400) AS nightly_report%' LIMIT 1")"
got="$(answer sleeper_os_thread)"
if [ -z "$live" ]; then
  fail "sleeper_os_thread: the nightly_report connection is gone"
  hint "it was killed or the server restarted; run the setup again"
elif [ "$got" = "$live" ]; then
  pass "sleeper_os_thread = $got"
else
  fail "sleeper_os_thread is '$got'"
  hint "performance_schema.threads maps PROCESSLIST_ID to THREAD_OS_ID"
fi

# 2. Write -> binary log file ----------------------------------------------
expected="$(dc exec -T primary cat /tmp/01-architecture-tour.binlog 2>/dev/null || true)"
got="$(answer audit_binlog_file)"
if [ -z "$expected" ]; then
  fail "audit_binlog_file: setup state is missing; run the setup again"
elif [ "${got##*/}" = "$expected" ]; then
  pass "audit_binlog_file = $got"
else
  fail "audit_binlog_file is '$got'"
  hint "the current file is not the answer; SHOW BINARY LOGS, then SHOW BINLOG EVENTS IN '<file>'"
fi

# 3. Table -> buffer pool pages (within 5%: the pool is live) ----------------
live="$(sqlv primary "SELECT COUNT(*) FROM information_schema.INNODB_BUFFER_PAGE
                      WHERE TABLE_NAME = '\`shop\`.\`orders\`' AND INDEX_NAME = 'PRIMARY'")"
got="$(answer orders_primary_pages)"
case "$got" in
  ''|*[!0-9]*) fail "orders_primary_pages is '$got', not a number"
               hint "count rows in information_schema.INNODB_BUFFER_PAGE" ;;
  *) diff=$(( got > live ? got - live : live - got ))
     if [ $(( diff * 100 )) -le $(( live * 5 )) ] && [ "$live" -gt 0 ]; then
       pass "orders_primary_pages = $got (now $live)"
     else
       fail "orders_primary_pages is $got, the buffer pool now holds $live"
       hint "filter on TABLE_NAME = '\`shop\`.\`orders\`' AND INDEX_NAME = 'PRIMARY'"
     fi ;;
esac

# 4. Table -> tablespace file ----------------------------------------------
got="$(answer audit_log_old_file)"
if [ "${got##*/}" = "ibdata1" ]; then
  pass "audit_log_old_file = $got"
else
  fail "audit_log_old_file is '$got'"
  hint "INNODB_TABLES gives the SPACE id; information_schema.FILES maps it to a file"
fi

# 5. lab.audit_log moved to its own .ibd, rows intact ------------------------
space="$(sqlv primary "SELECT IFNULL(s.NAME, CONCAT('space ', t.SPACE))
                       FROM information_schema.INNODB_TABLES t
                       LEFT JOIN information_schema.INNODB_TABLESPACES s USING (SPACE)
                       WHERE t.NAME = 'lab/audit_log'")"
expect "lab.audit_log lives in its own tablespace" "$space" "lab/audit_log"
[ "$space" = "lab/audit_log" ] || hint "ALTER TABLE ... TABLESPACE innodb_file_per_table"
expect "lab.audit_log still has all 501 rows" \
  "$(sqlv primary "SELECT COUNT(*) FROM lab.audit_log" 2>/dev/null || echo missing)" "501"

check_result
