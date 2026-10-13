# shellcheck shell=bash
# Helpers shared by the 08-saturation-alert scripts. Sourced after lib.sh.

PILEUP_CONTAINER="${DBRE_PROJECT}-08-pileup"
# The student's rule file, as seen on the host and inside the Prometheus container.
# shellcheck disable=SC2034  # used by check.sh, solve.sh and reset.sh
RULE_FILE="$LAB_DIR/observability/prometheus/rules.d/saturation.yml"
# shellcheck disable=SC2034  # used by check.sh
RULE_FILE_IN_PROM="/etc/prometheus/dbre/rules.d/saturation.yml"

pileup_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$PILEUP_CONTAINER" 2>/dev/null)" = "true" ]
}

# The blocking session: holds the row lock inside its open transaction.
blocker_present() {
  [ "$(sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist
                     WHERE INFO LIKE 'DO SLEEP(86400), ''dbre-08-pileup''%'")" -ge 1 ]
}

start_pileup() {
  local cid image network
  cid="$(dc ps -q primary)"
  image="$(docker inspect -f '{{.Config.Image}}' "$cid")"
  network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$cid" | awk '{print $1}')"
  docker run -d --rm --name "$PILEUP_CONTAINER" --network "$network" \
    --label "dbre.project=$DBRE_PROJECT" --label dbre.scenario=08-saturation-alert \
    --entrypoint bash "$image" -c "$(cat "$LAB_DIR/scenarios/08-saturation-alert/pileup.sh")" >/dev/null
}

stop_pileup() {
  local ids id
  docker rm -f "$PILEUP_CONTAINER" >/dev/null 2>&1 || true
  # The server notices a vanished client only when it next talks to it, so
  # kill the tagged sessions explicitly (waiters first, then the blocker).
  ids="$(sqlv primary "SELECT ID FROM performance_schema.processlist
                       WHERE INFO LIKE '%dbre-08-pileup%' AND INFO NOT LIKE '%processlist%'
                       ORDER BY INFO LIKE 'DO SLEEP%'")"
  for id in $ids; do
    sql primary -e "KILL $id" 2>/dev/null || true
  done
}

prometheus_up() {
  is_running prometheus
}

# prom_query "<PromQL>" — instant query, one series per line ('' when empty).
prom_query() {
  dc exec -T prometheus promtool query instant http://localhost:9090 "$1" 2>&1
}

prom_reload() {
  dc exec -T prometheus wget -qO- --post-data='' http://localhost:9090/-/reload 2>&1
}
