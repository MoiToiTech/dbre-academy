#!/usr/bin/env bash
# summary: Someone "tested a fix" on the replica; now its applier stops with errors 1062 and 1032
. "$LAB_DIR/scripts/lib.sh"

# Start from a clean state even if a previous run was not reset.
bash "$LAB_DIR/scenarios/07-broken-replication/reset.sh" >/dev/null

DIR=/backups/07-broken-replication
primary_gtids="$(sqlv primary 'SELECT @@GLOBAL.gtid_executed' | tr -d '\n')"

# Errant transactions that existed before this scenario are not the
# student's problem; remember them so check.sh only judges new ones.
before="$(sqlv replica "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$primary_gtids')" | tr -d '\n')"
dc exec -T primary bash -c "mkdir -p $DIR && printf '%s' '$before' > $DIR/.errant-before"

# 1. Last night, during an incident, someone switched off the replica's
#    write protection and "tested" two changes directly on it.
sql replica <<'SQL'
SET GLOBAL super_read_only = OFF;
INSERT INTO shop.customers (id, email, full_name, country_code, status, created_at)
VALUES (20001, 'customer20001@example.test', 'Test Account', 'EE', 'active',
        '2026-03-01 23:40:00');
DELETE FROM shop.inventory WHERE product_id = 7 AND warehouse = 'RIX';
SET GLOBAL super_read_only = ON;
SQL

# 2. This morning the application signs up a new customer, who orders at
#    once, and the warehouse books stock out of Riga.
sql primary <<'SQL'
INSERT INTO shop.customers (id, email, full_name, country_code, status, created_at)
VALUES (20001, 'customer20001@example.test', 'Liis Kask', 'LV', 'active',
        '2026-03-02 08:12:00');
UPDATE shop.inventory SET on_hand = on_hand - 2, updated_at = '2026-03-02 08:15:00'
 WHERE product_id = 7 AND warehouse = 'RIX';
INSERT INTO shop.orders (id, customer_id, status, total_cents, created_at, updated_at)
VALUES (200001, 20001, 'paid', 4598, '2026-03-02 08:14:00', '2026-03-02 08:14:00');
INSERT INTO shop.order_items (order_id, line_no, product_id, quantity, price_cents)
VALUES (200001, 1, 7, 2, 2299);
INSERT INTO shop.payments (id, order_id, method, amount_cents, status, created_at)
VALUES (1000001, 200001, 'card', 4598, 'captured', '2026-03-02 08:14:20');
SQL

# 3. Wait for the applier to trip over it.
for _ in $(seq 60); do
  [ "$(sqlv replica "SELECT COUNT(*) FROM performance_schema.replication_applier_status_by_worker
                     WHERE LAST_ERROR_NUMBER <> 0")" != "0" ] && break
  sleep 0.5
done

cat <<'MSG'
Scenario 07-broken-replication is set up.

  Monitoring says the replica stopped applying changes this morning, and
  its lag keeps growing. Nobody has touched it today, they say.

  Get replication running again WITHOUT losing consistency: the replica
  must end with exactly the primary's data, and with no transactions of its
  own that the primary does not have. Then: ./lab check 07-broken-replication
MSG
