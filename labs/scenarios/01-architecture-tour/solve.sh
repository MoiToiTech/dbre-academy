#!/usr/bin/env bash
# Reference solution. Try the exercise first.
. "$LAB_DIR/scripts/lib.sh"

# 1. The connection's OS thread.
sql primary -e "
UPDATE lab.answers SET answer = (
  SELECT THREAD_OS_ID FROM performance_schema.threads
  WHERE PROCESSLIST_INFO LIKE 'SELECT SLEEP(86400) AS nightly_report%')
WHERE question = 'sleeper_os_thread'"

# 2. Walk the binary logs from the newest back; the first one with a row
#    event for lab.audit_log holds the marker.
for f in $(sqlv primary "SHOW BINARY LOGS" | cut -f1 | sort -r); do
  events="$(sqlv primary "SHOW BINLOG EVENTS IN '$f'")"
  if grep -q "Table_map.*(lab.audit_log)" <<<"$events"; then
    sql primary -e "UPDATE lab.answers SET answer = '$f' WHERE question = 'audit_binlog_file'"
    break
  fi
done

# 3. Read the whole clustered index, then count its pages in the pool.
sql primary -e "
SELECT SUM(total_cents) FROM shop.orders;
UPDATE lab.answers SET answer = (
  SELECT COUNT(*) FROM information_schema.INNODB_BUFFER_PAGE
  WHERE TABLE_NAME = '\`shop\`.\`orders\`' AND INDEX_NAME = 'PRIMARY')
WHERE question = 'orders_primary_pages'" >/dev/null

# 4 + 5. Find the file, then move the table to file-per-table.
sql primary -e "
UPDATE lab.answers SET answer = (
  SELECT f.FILE_NAME FROM information_schema.INNODB_TABLES t
  JOIN information_schema.FILES f ON f.FILE_ID = t.SPACE
  WHERE t.NAME = 'lab/audit_log')
WHERE question = 'audit_log_old_file';
ALTER TABLE lab.audit_log TABLESPACE innodb_file_per_table;"
