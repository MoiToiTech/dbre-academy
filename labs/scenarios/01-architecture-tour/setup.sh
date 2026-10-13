#!/usr/bin/env bash
# summary: Architecture tour: trace a connection to its OS thread, a write to its binlog file, a table to its pages
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean slate if a previous run was left behind.
bash "$LAB_DIR/scenarios/01-architecture-tour/reset.sh" >/dev/null

info "Creating the lab schema, the answers table and lab.audit_log"
sql primary <<'SQL'
CREATE DATABASE lab;
CREATE TABLE lab.answers (
  question VARCHAR(40)  NOT NULL PRIMARY KEY,
  asks     VARCHAR(200) NOT NULL,
  answer   VARCHAR(255) NULL
);
INSERT INTO lab.answers (question, asks) VALUES
  ('sleeper_os_thread',    'OS thread id (LWP) serving the connection running nightly_report'),
  ('audit_binlog_file',    'Binary log file that holds the setup marker row inserted into lab.audit_log'),
  ('orders_primary_pages', 'Pages of the PRIMARY index of shop.orders now in the buffer pool'),
  ('audit_log_old_file',   'File that held lab.audit_log before you moved it');

-- Someone created this table in the system tablespace. Space used here is
-- never returned to the file system, even after DROP TABLE.
CREATE TABLE lab.audit_log (
  id         INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  created_at DATETIME     NOT NULL,
  event      VARCHAR(100) NOT NULL
) ENGINE=InnoDB TABLESPACE innodb_system;

INSERT INTO lab.audit_log (created_at, event)
WITH RECURSIVE n (i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 500)
SELECT '2026-01-01 00:00:00' + INTERVAL i MINUTE, CONCAT('login customer', i)
FROM n;
SQL

# The marker row goes into a binary log file of its own: rotate before and
# after, so the answer is neither the first nor the current file.
sql primary -e "FLUSH BINARY LOGS"
marker_file="$(sqlv primary "INSERT INTO lab.audit_log (created_at, event)
                              VALUES ('2026-01-02 09:00:00', 'setup marker: price list approved');
                              SHOW BINARY LOG STATUS" | cut -f1)"
sql primary -e "FLUSH BINARY LOGS"
dc exec -T primary bash -c "echo '$marker_file' > /tmp/01-architecture-tour.binlog"

info "Starting the nightly_report connection (user app, sleeps for a day)"
dc exec -d -T -e MYSQL_PWD=dbre-lab-app primary bash -c \
  'echo $$ > /tmp/01-architecture-tour.pid; exec mysql -uapp -h127.0.0.1 -e "SELECT SLEEP(86400) AS nightly_report"'
for _ in $(seq 1 20); do
  [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.threads
                     WHERE PROCESSLIST_INFO LIKE 'SELECT SLEEP(86400) AS nightly_report%'")" = "1" ] && break
  sleep 0.5
done

echo
echo "Scenario ready. Record four answers in lab.answers and move lab.audit_log"
echo "out of the system tablespace. See exercise.md; check with:"
echo "  ./lab scenario check 01-architecture-tour"
