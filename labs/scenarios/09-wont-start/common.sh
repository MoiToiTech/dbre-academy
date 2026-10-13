# shellcheck shell=bash disable=SC2034
# (SC2034: the constants here are used by the scripts that source this file.)
# Helpers shared by the 09-wont-start scripts. Sourced after lib.sh.

RESCUE="${DBRE_PROJECT}-rescue"
VOLUME="${DBRE_PROJECT}_primary-data"

primary_cid() { dc ps -aq primary 2>/dev/null | head -n1; }

primary_state() {
  local cid
  cid="$(primary_cid)"
  [ -n "$cid" ] || { echo missing; return; }
  docker inspect -f '{{.State.Status}}' "$cid"
}

# The image the primary runs, read from its container so that a retagged
# image (dbre-academy/mysql:8.4) is followed without editing this file.
lab_image() {
  local cid
  cid="$(primary_cid)"
  if [ -n "$cid" ]; then docker inspect -f '{{.Config.Image}}' "$cid"
  else echo "dbre-academy/mysql:8.4"; fi
}

# wait_exited <seconds> — wait for the primary container to stop.
wait_exited() {
  local timeout="$1" waited=0
  while [ "$(primary_state)" != "exited" ]; do
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1; waited=$((waited + 1))
  done
}

# rescue_reset_persist <var>... — start a throwaway mysqld on the primary's
# data volume, isolated from the network, that ignores mysqld-auto.cnf; remove
# the named persisted settings with RESET PERSIST IF EXISTS; shut it down.
rescue_reset_persist() {
  local stmt="" v waited=0
  for v in "$@"; do stmt="$stmt RESET PERSIST IF EXISTS $v;"; done
  docker rm -f "$RESCUE" >/dev/null 2>&1 || true
  docker run -d --name "$RESCUE" --network none \
    -v "$VOLUME:/var/lib/mysql" \
    -v "$LAB_DIR/mysql/primary.cnf:/etc/mysql/conf.d/dbre.cnf:ro" \
    "$(lab_image)" mysqld --persisted-globals-load=OFF >/dev/null
  until docker exec "$RESCUE" mysqladmin -uroot -p"$DBRE_ROOT_PASSWORD" ping --silent >/dev/null 2>&1; do
    [ "$waited" -ge 120 ] && { docker logs --tail 20 "$RESCUE" >&2; die "rescue mysqld did not start"; }
    sleep 2; waited=$((waited + 2))
  done
  docker exec -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" "$RESCUE" mysql -uroot -e "$stmt"
  # The container exits with mysqld, which can make docker exec report an
  # error even though the shutdown was clean; docker wait gives the verdict.
  docker exec -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" "$RESCUE" mysqladmin -uroot shutdown \
    >/dev/null 2>&1 || true
  [ "$(docker wait "$RESCUE")" = "0" ] || die "rescue mysqld did not shut down cleanly"
  case "$(docker logs --tail 5 "$RESCUE" 2>&1)" in
    *"Shutdown complete"*) ;;
    *) die "rescue mysqld did not report a clean shutdown" ;;
  esac
  docker rm "$RESCUE" >/dev/null
}

# start_primary — start (or recreate) the primary container and wait for it.
start_primary() {
  dc up -d primary >/dev/null 2>&1
  wait_healthy primary 180
}

# replica_running — prints ON/ON when both replication threads run.
replica_threads() {
  sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                FROM performance_schema.replication_connection_status c
                JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)"
}
