#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

# Reload the canonical dataset on the primary (binary-logged, so a healthy
# replica follows). If the replica is stopped, divergent or carries errant
# transactions from this scenario, rebuild it from a dump of the primary.

DIR=/backups/07-broken-replication
FP_SQL="$LAB_DIR/datasets/shop/fingerprint.sql"

replica_ok() {
  [ "$(sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE, '/',
                       (SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker
                         WHERE LAST_ERROR_NUMBER <> 0))
                     FROM performance_schema.replication_connection_status c
                     JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)")" = "ON/ON/0" ] \
    && wait_replica_caught_up 180 \
    && [ "$(sql primary -N -B < "$FP_SQL")" = "$(sql replica -N -B < "$FP_SQL")" ]
}

rebuild_replica() {
  info "Rebuilding the replica from a dump of the primary"
  local dbs
  dbs="$(sqlv primary "SELECT GROUP_CONCAT(SCHEMA_NAME SEPARATOR ' ') FROM information_schema.SCHEMATA
                       WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema')")"
  dc exec -T -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" primary bash -c "
    mysqldump -uroot --single-transaction --set-gtid-purged=ON --routines --events \
      --triggers --add-drop-database --databases $dbs > /backups/.rebuild-replica.sql 2>/dev/null"
  {
    echo "STOP REPLICA; RESET REPLICA; SET GLOBAL super_read_only = OFF;"
    echo "SET SESSION sql_log_bin = 0;"
    sqlv replica "SELECT CONCAT('DROP DATABASE \`', SCHEMA_NAME, '\`;') FROM information_schema.SCHEMATA
                  WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema')"
    echo "RESET BINARY LOGS AND GTIDS;"
    echo "SOURCE /backups/.rebuild-replica.sql"
    echo "SET GLOBAL super_read_only = ON; START REPLICA;"
  } | sql replica
  dc exec -T primary rm -f /backups/.rebuild-replica.sql
}

# Errant transactions this scenario created (the replica's own, beyond any
# that existed before setup).
new_errant=""
if before="$(dc exec -T primary cat "$DIR/.errant-before" 2>/dev/null)"; then
  pg="$(sqlv primary 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
  new_errant="$(sqlv replica "SELECT GTID_SUBTRACT(GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$pg'), '$before')" | tr -d '\n')"
fi

sql replica -e "SET GLOBAL super_read_only = ON"
sql primary -e "source /datasets/shop/01-schema.sql"
sql primary -e "source /datasets/shop/02-data.sql" >/dev/null
sql primary -e "DROP DATABASE IF EXISTS lab"
if [ -n "$new_errant" ] || ! replica_ok; then
  rebuild_replica
  wait_replica_caught_up 180 || warn "replica is behind the primary — run ./lab status"
fi
dc exec -T primary rm -rf "$DIR"
echo "07-broken-replication reset."
