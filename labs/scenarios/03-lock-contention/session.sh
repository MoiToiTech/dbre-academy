#!/usr/bin/env bash
# Runs INSIDE the primary container (started by setup.sh with docker compose
# exec -d), so the sessions outlive setup.sh. Not for students to run.
#
#   session.sh blocker            open a transaction, lock product 42, go idle
#   session.sh victim <warehouse> update one locked row; retry after 1205
#
# Every process writes its pid to $RUN_DIR; reset.sh kills them from there.
set -u
RUN_DIR=/tmp/dbre-03-lock-contention
mkdir -p "$RUN_DIR"
export MYSQL_PWD=dbre-lab-app
MARK="SET @dbre_scenario='03-lock-contention'"

case "${1:-}" in
  blocker)
    # The application opened a transaction, reserved stock and then stopped
    # talking to the database without committing: idle in transaction.
    coproc APP { exec mysql -uapp -N --init-command="$MARK" shop >/dev/null 2>&1; }
    echo "$APP_PID" > "$RUN_DIR/blocker-client.pid"
    echo "$$" > "$RUN_DIR/blocker.pid"
    trap 'kill "$APP_PID" 2>/dev/null; wait "$APP_PID"; exit 0' TERM INT
    printf '%s\n' \
      "START TRANSACTION;" \
      "UPDATE inventory SET reserved = reserved + 5, updated_at = NOW() WHERE product_id = 42;" \
      >&"${APP[1]}"
    wait "$APP_PID"
    ;;
  victim)
    wh="${2:?warehouse}"
    echo "$$" > "$RUN_DIR/victim-$wh.pid"
    trap 'kill $(jobs -p) 2>/dev/null; wait; exit 0' TERM INT
    # Retry on lock wait timeout, as many application frameworks do. Gives up
    # after two hours so that a forgotten lab cannot keep it alive forever.
    for _ in $(seq 360); do
      mysql -uapp -N --init-command="$MARK" shop -e \
        "UPDATE inventory SET reserved = reserved + 1, updated_at = NOW()
          WHERE product_id = 42 AND warehouse = '$wh'" >/dev/null 2>&1 &
      client=$!
      echo "$client" > "$RUN_DIR/victim-$wh-client.pid"
      if wait "$client"; then break; fi
      sleep 1 & wait $!
    done
    rm -f "$RUN_DIR/victim-$wh.pid" "$RUN_DIR/victim-$wh-client.pid"
    ;;
  *) echo "usage: $0 blocker | victim <warehouse>" >&2; exit 2 ;;
esac
