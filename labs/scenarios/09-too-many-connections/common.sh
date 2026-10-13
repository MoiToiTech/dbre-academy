# shellcheck shell=bash disable=SC2034
# (SC2034: the constants here are used by the scripts that source this file.)
# Helpers shared by the 09-too-many-connections scripts. Sourced after lib.sh.

WORKER="${DBRE_PROJECT}-invoice-worker"
LEAK_SLOTS=40          # connections the worker tries to hold
LOW_LIMIT=30           # max_connections the scenario persists
SANE_LIMIT=150         # the check accepts this or more

lab_image() {
  docker inspect -f '{{.Config.Image}}' "$(dc ps -q primary)"
}

worker_running() {
  [ -n "$(docker ps -q --filter "name=^${WORKER}$")" ]
}

worker_ip() {
  worker_running || return 0
  docker inspect -f "{{(index .NetworkSettings.Networks \"${DBRE_PROJECT}_default\").IPAddress}}" "$WORKER"
}

# Connections currently held by the worker container.
worker_connections() {
  local ip
  ip="$(worker_ip)"
  [ -n "$ip" ] || { echo 0; return; }
  sqlv primary "SELECT COUNT(*) FROM performance_schema.processlist
                WHERE USER = 'app' AND HOST LIKE '${ip}:%'"
}

# Start the leaking worker: LEAK_SLOTS loops, each holding one idle app
# connection and reconnecting two seconds after losing it — the behaviour of
# a connection pool with no upper bound. The Compose labels make
# './lab destroy' remove it as an orphan of the lab project.
start_worker() {
  docker rm -f "$WORKER" >/dev/null 2>&1 || true
  docker run -d --name "$WORKER" --hostname invoice-worker \
    --network "${DBRE_PROJECT}_default" \
    --label "com.docker.compose.project=${DBRE_PROJECT}" \
    --label com.docker.compose.service=invoice-worker \
    --label com.docker.compose.oneoff=False \
    --label com.docker.compose.config-hash=scenario-09 \
    -e MYSQL_PWD=dbre-lab-app -e SLOTS="$LEAK_SLOTS" \
    --entrypoint bash "$(lab_image)" -c '
      slot() {
        while :; do
          { while :; do echo "DO 0;"; sleep 5; done; } \
            | mysql -hprimary -uapp shop 2>/dev/null
          sleep 2
        done
      }
      for i in $(seq 1 "$SLOTS"); do slot & done
      wait' >/dev/null
}

stop_worker() {
  docker rm -f "$WORKER" >/dev/null 2>&1 || true
}
