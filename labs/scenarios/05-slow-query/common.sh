# shellcheck shell=bash
# Helpers shared by the 05-slow-query scripts. Sourced after lib.sh.

WORKLOAD_CONTAINER="${DBRE_PROJECT}-05-workload"

# The offending statement exactly as the application sends it (one sample day).
OFFENDER_SQL="SELECT COUNT(*), SUM(total_cents) FROM orders WHERE DATE(created_at) = '2025-03-14'"

# Indexes and columns of shop.orders in the baseline dataset. reset.sh drops
# anything else the student (or solve.sh) added to the table.
# shellcheck disable=SC2034  # used by reset.sh
BASELINE_INDEXES="'PRIMARY','idx_orders_customer'"
# shellcheck disable=SC2034  # used by reset.sh
BASELINE_COLUMNS="'id','customer_id','status','total_cents','created_at','updated_at'"

workload_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$WORKLOAD_CONTAINER" 2>/dev/null)" = "true" ]
}

start_workload() {
  local cid image network
  cid="$(dc ps -q primary)"
  image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
  network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid" | awk '{print $1}')"
  docker run -d --rm --name "$WORKLOAD_CONTAINER" --network "$network" \
    --label "dbre.project=$DBRE_PROJECT" --label dbre.scenario=05-slow-query \
    --entrypoint bash "$image" -c "$(cat "$LAB_DIR/scenarios/05-slow-query/workload.sh")" >/dev/null
}

stop_workload() {
  docker rm -f "$WORKLOAD_CONTAINER" >/dev/null 2>&1 || true
}

# offender_digest — the normalised digest hash of the offending statement.
offender_digest() {
  sql primary -N -B -D shop -e "SELECT STATEMENT_DIGEST(\"$OFFENDER_SQL\")"
}
