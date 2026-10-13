# shellcheck shell=bash disable=SC2034
# (SC2034: the constants here are used by the scripts that source this file.)
# Helpers shared by the 10-final-incident scripts. Sourced after lib.sh.
#
# Three independent faults:
#   1. checkout   — an idle back-office transaction holds row locks on
#                   shop.inventory; checkout updates time out (ERROR 1205).
#   2. api        — a new API query on shop.orders has no usable index and
#                   scans the table on every call under steady load.
#   3. replica    — a row was deleted on the replica only; the next primary
#                   update of that row stops the applier (ERROR 1032), so the
#                   reports that read the replica go stale.

APP="${DBRE_PROJECT}-shop-app"
CONSOLE="${DBRE_PROJECT}-backoffice-console"
PAYMENT_ID=4242                      # captured in the dataset; refunded by the incident
STATE_FILE=/tmp/dbre-10-final-incident.gtids   # inside the replica container

API_QUERY="SELECT id, customer_id, total_cents, created_at FROM shop.orders
           WHERE status = 'pending' ORDER BY created_at DESC LIMIT 50"

lab_image() {
  docker inspect -f '{{.Config.Image}}' "$(dc ps -q primary)"
}

running() { [ -n "$(docker ps -q --filter "name=^$1$")" ]; }

# run_side <name> <service-label> <script> [docker run args...]
# A container on the lab network, labelled so './lab destroy' removes it
# as an orphan of the lab project.
run_side() {
  local name="$1" svc="$2" script="$3"; shift 3
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --hostname "$svc" \
    --network "${DBRE_PROJECT}_default" \
    --label "com.docker.compose.project=${DBRE_PROJECT}" \
    --label "com.docker.compose.service=$svc" \
    --label com.docker.compose.oneoff=False \
    --label com.docker.compose.config-hash=scenario-10 \
    "$@" --entrypoint bash "$(lab_image)" -c "$script" >/dev/null
}

# The back-office console: a stock correction typed into an interactive
# client, never committed. The session then sits idle, holding its locks.
start_console() {
  run_side "$CONSOLE" backoffice-console '
    { echo "START TRANSACTION;"
      echo "UPDATE inventory SET on_hand = on_hand + 10 WHERE warehouse = '\''TLL'\'' AND product_id BETWEEN 1 AND 50;"
      sleep infinity
    } | mysql -hprimary -ubackoffice shop' \
    -e MYSQL_PWD=dbre-lab-backoffice
}

# The shop application: three checkout workers (reserve stock, then roll
# back so the dataset never changes) and four API workers polling the new
# "pending orders" endpoint. It writes an access log to its container log.
# The script is single-quoted on purpose: it expands inside the container.
# shellcheck disable=SC2016
start_app() {
  run_side "$APP" shop-app '
    now() { date -u +%H:%M:%S; }
    ms()  { echo $(( ($(date +%s%N) - $1) / 1000000 )); }
    checkout() {
      sleep $(( ($1 - 1) * 7 ))   # staggered, so that someone is always waiting
      while :; do
        p=$(( RANDOM % 50 + 1 )); t=$(date +%s%N)
        if out=$(mysql -c -hprimary -uapp shop -e "START TRANSACTION;
              UPDATE /* checkout:reserve */ inventory SET reserved = reserved + 1
              WHERE product_id = $p AND warehouse = '\''TLL'\''; ROLLBACK;" 2>&1); then
          echo "$(now) checkout-$1 POST /checkout sku=$p 200 $(ms "$t")ms"
        else
          echo "$(now) checkout-$1 POST /checkout sku=$p 500 $(ms "$t")ms ${out#ERROR }"
        fi
        sleep 2
      done
    }
    api() {
      while :; do
        n=0; t=$(date +%s%N)
        while [ $(( ($(date +%s%N) - t) / 1000000 )) -lt 10000 ]; do
          for i in 1 2 3 4 5 6 7 8 9 10; do
            echo "SELECT /* api:orders.pending */ id, customer_id, total_cents, created_at FROM orders WHERE status = '\''pending'\'' ORDER BY created_at DESC LIMIT 50;"
          done | mysql -c -hprimary -uapp shop >/dev/null 2>&1 || true
          n=$((n + 10))
        done
        echo "$(now) api-$1 GET /v2/orders?status=pending $n requests in 10s, avg $(( $(ms "$t") * 1000 / n ))us"
      done
    }
    for w in 1 2 3; do checkout "$w" & done
    for w in 1 2 3 4; do api "$w" & done
    wait' \
    -e MYSQL_PWD=dbre-lab-app
}

replica_threads() {
  sqlv replica "SELECT CONCAT(c.SERVICE_STATE, '/', a.SERVICE_STATE)
                FROM performance_schema.replication_connection_status c
                JOIN performance_schema.replication_applier_status a USING (CHANNEL_NAME)"
}

payments_sum() {
  sqlv "$1" "SELECT CONCAT(COUNT(*), ':', SUM(CRC32(CONCAT_WS('|', id, order_id, method,
                    amount_cents, status, created_at)))) FROM shop.payments"
}

# GTIDs the replica has that the primary does not. Empty on a lab built by
# ./lab up (it clears the replica's own initialisation GTIDs), but a student
# may arrive with some; the value saved at setup is the baseline against
# which new (errant) transactions are detected.
replica_only_gtids() {
  local p
  p="$(sqlv primary "SELECT @@GLOBAL.gtid_executed" | tr -d '\n')"
  sqlv replica "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$p')" | tr -d '\n'
}

saved_replica_only_gtids() {
  dc exec -T replica cat "$STATE_FILE" 2>/dev/null || true
}

# Whether setup saved a baseline. An empty baseline is normal, so the
# saved value alone cannot tell "nothing saved" from "nothing errant".
has_saved_replica_only_gtids() {
  dc exec -T replica test -f "$STATE_FILE" 2>/dev/null
}
