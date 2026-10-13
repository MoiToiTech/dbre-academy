#!/usr/bin/env bash
# The order service: checkout queues confirmation e-mails in the outbox (the
# producer), and two workers claim the oldest pending messages and send them.
# Each loop keeps one connection open and reconnects if it is dropped.
set -u
DB=(mysql -hdb -uapp -papp-local-only --batch --force --silent shop)

until "${DB[@]}" -e 'SELECT 1' >/dev/null 2>&1; do sleep 1; done
echo "order service: connected"

producer() {
  local n=0
  while :; do
    n=$(( (n % 20000) + 1 ))
    echo "INSERT INTO outbox (order_id, kind, payload) VALUES ($n, 'order_confirmation', JSON_OBJECT('order_id', $n, 'template', 'confirmation_v3'));"
    sleep 0.02
  done
}

worker() {
  while :; do
    echo "UPDATE outbox SET status = 'sent', sent_at = NOW(3) WHERE status = 'pending' ORDER BY id LIMIT 10;"
    sleep 0.1
  done
}

supervise() {
  local name=$1
  while :; do
    "$name" | "${DB[@]}" >/dev/null 2>&1
    echo "order service: $name connection lost, reconnecting"
    sleep 1
  done
}

supervise producer &
supervise worker &
supervise worker &
wait
