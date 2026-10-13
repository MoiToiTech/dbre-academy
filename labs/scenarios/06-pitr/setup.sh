#!/usr/bin/env bash
# summary: Last night's backup, a morning of orders, and a DELETE that wiped the failed payments
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean state even if a previous run was not reset.
bash "$LAB_DIR/scenarios/06-pitr/reset.sh" >/dev/null

DIR=/backups/pitr
FP="$(cat "$LAB_DIR/datasets/shop/fingerprint.sql")"
# The payments line of fingerprint.sql, for one subset of rows.
PAY_SUM="COUNT(*), SUM(CRC32(CONCAT_WS('|', id, order_id, method, amount_cents, status, created_at)))"

# 1. The nightly logical backup. --set-gtid-purged=OFF is deliberate: this
#    backup is restored in place on a replicated primary, so the load must be
#    binary-logged (ON and COMMENTED both add SET @@SESSION.SQL_LOG_BIN=0).
dc exec -T -e MYSQL_PWD="$DBRE_ROOT_PASSWORD" primary bash -c "
  set -euo pipefail
  mkdir -p $DIR
  mysqldump -uroot --single-transaction --source-data=2 --set-gtid-purged=OFF \
    --routines --events --triggers --add-drop-database --databases shop \
    > $DIR/shop-full.sql
  sha256sum $DIR/shop-full.sql > $DIR/shop-full.sql.sha256"

# 2. A morning of ordinary writes. Every value is fixed, so every run
#    produces the same rows.
new_orders() { # new_orders <first n> <last n> <minute offset>
  sql primary <<SQL
INSERT INTO shop.orders (id, customer_id, status, total_cents, created_at, updated_at)
SELECT 200000 + n, 1 + (n * 37) % 20000, 'paid', 1000 + n * 13,
       '2026-03-02 08:00:00' + INTERVAL ($3 + n) MINUTE,
       '2026-03-02 08:00:00' + INTERVAL ($3 + n) MINUTE
  FROM (WITH RECURSIVE s (n) AS (SELECT $1 UNION ALL SELECT n + 1 FROM s WHERE n < $2)
        SELECT n FROM s) AS seq;
INSERT INTO shop.order_items (order_id, line_no, product_id, quantity, price_cents)
SELECT 200000 + n, 1, 1 + (n * 13) % 1000, 1, 1000 + n * 13
  FROM (WITH RECURSIVE s (n) AS (SELECT $1 UNION ALL SELECT n + 1 FROM s WHERE n < $2)
        SELECT n FROM s) AS seq;
INSERT INTO shop.payments (id, order_id, method, amount_cents, status, created_at)
SELECT 1000000 + n, 200000 + n, ELT(1 + n % 3, 'card', 'bank_transfer', 'wallet'),
       1000 + n * 13, IF(n % 5 = 0, 'failed', 'captured'),
       '2026-03-02 08:00:30' + INTERVAL ($3 + n) MINUTE
  FROM (WITH RECURSIVE s (n) AS (SELECT $1 UNION ALL SELECT n + 1 FROM s WHERE n < $2)
        SELECT n FROM s) AS seq;
SQL
}

new_orders 1 10 0
new_orders 11 20 0
new_orders 21 30 0
new_orders 31 40 0
sql primary <<'SQL'
UPDATE shop.orders SET status = 'shipped', updated_at = '2026-03-02 09:30:00'
 WHERE id BETWEEN 200001 AND 200010;
-- Support corrected the amount on a handful of old failed payments.
UPDATE shop.payments SET amount_cents = amount_cents + 100
 WHERE status = 'failed' AND id BETWEEN 1000 AND 1300;
SQL

# What the accident is about to remove, so the expected end state can be
# computed: the fingerprint checksum is a sum, so it is additive.
deleted="$(sqlv primary "SELECT $PAY_SUM FROM shop.payments WHERE status = 'failed'")"

# 3. The accident: a clean-up meant for failed payments older than 2023 ran
#    without its date predicate.
sql primary -e "DELETE FROM shop.payments WHERE status = 'failed'"

# 4. Business carries on: more orders (new failed payments among them) and
#    shipping updates. None of these touch a deleted row.
new_orders 41 50 30
new_orders 51 60 30
sql primary <<'SQL'
UPDATE shop.orders SET status = 'shipped', updated_at = '2026-03-02 11:15:00'
 WHERE id BETWEEN 200011 AND 200020;
UPDATE shop.inventory SET on_hand = on_hand - 1, updated_at = '2026-03-02 11:20:00'
 WHERE warehouse = 'TLL' AND product_id BETWEEN 1 AND 20;
SQL

# 5. Expected fingerprint = today's data plus the rows the DELETE removed.
expected="$(sql primary -N -B -e "$FP" | awk -v d="$deleted" '
  BEGIN { split(d, a, "\t") }
  $1 == "payments" { $2 += a[1]; $3 += a[2] }
  { printf "%s\t%.0f\t%.0f\n", $1, $2, $3 }')"
printf '%s\n' "$expected" | dc exec -T primary bash -c "cat > $DIR/.expected-fingerprint"

wait_replica_caught_up 120 || warn "replica is behind the primary — run ./lab status"

cat <<'MSG'
Scenario 06-pitr is set up.

  Last night's backup is /backups/pitr/shop-full.sql (on both containers).
  Since then the shop has taken orders, and at some point this morning
  someone ran a clean-up that deleted every failed payment, not just the old
  ones. More orders have come in after that.

  Bring shop back to the state it would be in had the clean-up never run,
  without losing anything else written this morning, on the primary AND the
  replica. Then: ./lab check 06-pitr
MSG
