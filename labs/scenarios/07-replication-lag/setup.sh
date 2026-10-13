#!/usr/bin/env bash
# summary: The replica falls further behind every second, though the primary is nearly idle
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean state even if a previous run was not reset.
bash "$LAB_DIR/scenarios/07-replication-lag/reset.sh" >/dev/null

RUN=/tmp/dbre-07-replication-lag
MARK="SET @dbre_scenario='07-replication-lag'"

# 1. A heartbeat: the primary stamps lab.heartbeat once a second. On the
#    replica, NOW() minus the stamp is the real replication delay.
sql primary <<'SQL'
CREATE DATABASE lab;
CREATE TABLE lab.heartbeat (id TINYINT UNSIGNED PRIMARY KEY, ts DATETIME(6) NOT NULL);
-- Scenario bookkeeping for reset.sh, written in the same transaction as
-- the change it records.
CREATE TABLE lab.applied (change_name VARCHAR(32) PRIMARY KEY);
INSERT INTO lab.heartbeat VALUES (1, NOW(6));
SQL
wait_replica_caught_up 60 || die "replica not caught up before setup — run ./lab status"
dc exec -d -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" primary bash -c "
  mkdir -p $RUN; echo \$\$ > $RUN/heartbeat.pid
  while :; do
    mysql -uroot -e 'UPDATE lab.heartbeat SET ts = NOW(6) WHERE id = 1' || true
    sleep 1
  done"

# 2. On the replica, a backup job's session took a global read lock to get
#    a consistent copy, then hung. Nothing on the replica can commit.
dc exec -d -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" replica bash -c "
  mkdir -p $RUN; echo \$\$ > $RUN/backup.pid
  exec mysql -uroot --init-command=\"$MARK\" -e 'FLUSH TABLES WITH READ LOCK; DO SLEEP(86400)'"
for _ in $(seq 30); do
  [ "$(sqlv replica "SELECT COUNT(*) FROM performance_schema.metadata_locks
                     WHERE OBJECT_TYPE = 'COMMIT' AND LOCK_STATUS = 'GRANTED'")" != "0" ] && break
  sleep 0.5
done

# 3. The application keeps writing: a price update on one category.
sql primary <<'SQL'
START TRANSACTION;
UPDATE shop.products SET price_cents = price_cents + 100 WHERE category = 'lighting';
INSERT INTO lab.applied VALUES ('lighting-price');
COMMIT;
SQL
# Let the delay build up past the check's threshold.
sleep 6

cat <<'MSG'
Scenario 07-replication-lag is set up.

  The reporting team says yesterday's numbers on the replica look stale, and
  the replica lag alert has started firing. The primary is barely busy.

  Find out why the replica is behind, fix the cause (waiting will not help),
  and let it catch up. Then: ./lab check 07-replication-lag
MSG
