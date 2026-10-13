# shellcheck shell=bash
# Shared helpers for ./lab and the scenario scripts. Source, don't execute.
# Written for bash 3.2 (macOS default): no associative arrays, no mapfile.

set -euo pipefail

LAB_DIR="${LAB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export LAB_DIR
export DBRE_PROJECT="${DBRE_PROJECT:-dbre}"
export DBRE_ROOT_PASSWORD="${DBRE_ROOT_PASSWORD:-dbre-lab-root}"
REPL_PASSWORD="dbre-lab-repl"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_DIM=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
warn() { printf '%sWARN%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# docker compose, scoped to this lab. All profiles are included so that
# down/ps also see the observability services.
dc() {
  docker compose -p "$DBRE_PROJECT" -f "$LAB_DIR/docker-compose.yml" "$@"
}
dc_all() {
  docker compose -p "$DBRE_PROJECT" -f "$LAB_DIR/docker-compose.yml" --profile observability "$@"
}

# The lab's MySQL image is built locally from mysql/Dockerfile. Rebuild it
# when the Dockerfile changed since the last build (tracked with a label).
DBRE_DOCKERFILE_SHA="$(cksum < "$LAB_DIR/mysql/Dockerfile" | awk '{print $1}')"
export DBRE_DOCKERFILE_SHA
ensure_image() {
  local built
  built="$(docker image inspect -f '{{index .Config.Labels "academy.dbre.dockerfile-sha"}}' \
           dbre-academy/mysql:8.4 2>/dev/null || true)"
  if [ "$built" != "$DBRE_DOCKERFILE_SHA" ]; then
    info "Building the lab's MySQL image (first run or Dockerfile changed; about a minute)"
    dc build --quiet primary
  fi
}

# sql <primary|replica> [mysql client args...]  — reads SQL from stdin if no -e.
sql() {
  local svc="$1"; shift
  dc exec -T -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" "$svc" mysql -uroot --default-character-set=utf8mb4 "$@"
}

# sqlv <primary|replica> "<query>"  — prints the bare value(s), no headers.
sqlv() {
  local svc="$1"; shift
  sql "$svc" -N -B -e "$1"
}

# is_running <service>
is_running() {
  [ -n "$(dc ps -q --status running "$1" 2>/dev/null)" ]
}

# wait_healthy <service> [timeout_seconds]
wait_healthy() {
  local svc="$1" timeout="${2:-180}" waited=0 cid state
  cid="$(dc ps -q "$svc")"
  [ -n "$cid" ] || die "service $svc has no container"
  while :; do
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
    case "$state" in
      healthy|running) return 0 ;;
      exited|dead) die "$svc stopped while starting — see: ./lab logs $svc" ;;
    esac
    [ "$waited" -ge "$timeout" ] && die "$svc not healthy after ${timeout}s (state: $state) — see: ./lab logs $svc"
    sleep 2; waited=$((waited + 2))
  done
}

# wait_replica_caught_up [timeout_seconds]
# Waits until every transaction executed on the primary is also executed on
# the replica (GTID set comparison, not Seconds_Behind_Source).
wait_replica_caught_up() {
  local timeout="${1:-120}" waited=0 gtids
  gtids="$(sqlv primary 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"
  while :; do
    if [ "$(sqlv replica "SELECT GTID_SUBSET('$gtids', @@GLOBAL.gtid_executed)")" = "1" ]; then
      return 0
    fi
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1; waited=$((waited + 1))
  done
}

# replication_configured — true if the replica has a source configured.
replication_configured() {
  [ "$(sqlv replica 'SELECT COUNT(*) FROM performance_schema.replication_connection_configuration')" != "0" ]
}

configure_replication() {
  if ! replication_configured; then
    info "Configuring GTID replication primary -> replica"
    # The image's entrypoint loads the time zone tables with binary logging
    # on, so a fresh replica starts with a few transactions under its own
    # server UUID: errant transactions that would follow it into any
    # failover. Clear them before it becomes a replica (module 7 explains).
    sql replica <<SQL
RESET BINARY LOGS AND GTIDS;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = 'primary',
  SOURCE_PORT = 3306,
  SOURCE_USER = 'repl',
  SOURCE_PASSWORD = '$REPL_PASSWORD',
  SOURCE_AUTO_POSITION = 1,
  SOURCE_SSL = 1,
  SOURCE_CONNECT_RETRY = 5;
SQL
  fi
  sql replica -e "SET PERSIST read_only = ON; SET PERSIST super_read_only = ON; START REPLICA;"
}

dataset_loaded() {
  [ "$(sqlv primary "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='shop' AND table_name='payments'")" = "1" ]
}

load_dataset() {
  local start=$SECONDS
  info "Loading the synthetic shop dataset on the primary (about a minute)"
  sql primary -e "source /datasets/shop/01-schema.sql"
  sql primary -e "source /datasets/shop/02-data.sql" >/dev/null
  info "Dataset loaded in $((SECONDS - start))s; waiting for the replica to apply it"
  wait_replica_caught_up 600 || die "replica did not catch up with the primary within 600s"
}

# --- result reporting for check scripts ------------------------------------

CHECK_FAILURES=0
pass() { printf '  %sPASS%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
fail() { printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$*"; CHECK_FAILURES=$((CHECK_FAILURES + 1)); }
hint() { printf '       %shint:%s %s\n' "$C_DIM" "$C_OFF" "$*"; }

# expect "<description>" "<actual>" "<expected>"
expect() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}

check_result() {
  if [ "$CHECK_FAILURES" -eq 0 ]; then
    printf '%sAll checks passed.%s\n' "$C_GREEN" "$C_OFF"; return 0
  else
    printf '%s%d check(s) failed.%s\n' "$C_RED" "$CHECK_FAILURES" "$C_OFF"; return 1
  fi
}
