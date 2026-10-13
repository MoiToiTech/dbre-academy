-- Deterministic data generator for the shop schema.
--
-- Every value is a pure function of a row number (via CRC32), so every run on
-- every machine produces byte-identical data. ./lab fingerprint checks that.
-- Emails use the reserved .test TLD (RFC 2606); names are invented.
--
-- Sizes: 20 000 customers, 1 000 products, 3 000 inventory rows,
-- 200 000 orders, ~500 000 order items, ~180 000 payments.

USE shop;
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION';
SET SESSION foreign_key_checks = 0;
SET SESSION unique_checks = 0;

-- A 0..999 999 number source built from digits; dropped at the end.
CREATE TABLE _digits (d TINYINT UNSIGNED PRIMARY KEY);
INSERT INTO _digits VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE _seq (n INT UNSIGNED PRIMARY KEY);
INSERT INTO _seq
SELECT a.d + 10*b.d + 100*c.d + 1000*e.d + 10000*f.d + 100000*g.d
FROM _digits a, _digits b, _digits c, _digits e, _digits f, _digits g;

-- Customers ---------------------------------------------------------------
INSERT INTO customers (id, email, full_name, country_code, status, created_at)
SELECT n,
       CONCAT('customer', n, '@example.test'),
       CONCAT(ELT(1 + CRC32(CONCAT('fn', n)) % 12,
                  'Mari','Jaan','Liis','Kalle','Anna','Peeter','Eva','Tõnu','Kati','Mihkel','Laura','Rasmus'),
              ' ',
              ELT(1 + CRC32(CONCAT('ln', n)) % 12,
                  'Tamm','Saar','Sepp','Mägi','Kask','Kukk','Rebane','Ilves','Lepik','Koppel','Mets','Vaher')),
       ELT(1 + CRC32(CONCAT('cc', n)) % 8, 'EE','FI','LV','LT','SE','DE','PL','NO'),
       CASE WHEN CRC32(CONCAT('cs', n)) % 100 < 95 THEN 'active'
            WHEN CRC32(CONCAT('cs', n)) % 100 < 98 THEN 'suspended'
            ELSE 'closed' END,
       TIMESTAMP('2023-01-01') + INTERVAL (CRC32(CONCAT('cd', n)) % 31536000) SECOND
FROM _seq WHERE n BETWEEN 1 AND 20000;

-- Products ----------------------------------------------------------------
INSERT INTO products (id, sku, name, category, price_cents)
SELECT n,
       CONCAT('SKU-', LPAD(n, 6, '0')),
       CONCAT(ELT(1 + CRC32(CONCAT('pa', n)) % 8,
                  'Compact','Heavy-duty','Marine','Field','Studio','Travel','Workshop','Outdoor'),
              ' ',
              ELT(1 + n % 10,
                  'lamp','cable','battery','sensor','charger','bracket','pump','filter','valve','switch'),
              ' ', n),
       ELT(1 + n % 10,
           'lighting','cables','power','sensors','power','hardware','plumbing','plumbing','plumbing','electrical'),
       500 + CRC32(CONCAT('pp', n)) % 49500
FROM _seq WHERE n BETWEEN 1 AND 1000;

INSERT INTO inventory (product_id, warehouse, on_hand, reserved, updated_at)
SELECT p.id, w.code,
       CRC32(CONCAT('inv', p.id, w.code)) % 500,
       0,
       TIMESTAMP('2025-12-31 23:00:00')
FROM products p
CROSS JOIN (SELECT 'TLL' AS code UNION ALL SELECT 'HEL' UNION ALL SELECT 'RIX') w;

-- Orders ------------------------------------------------------------------
-- customer_id is skewed: a minority of customers place most orders, as in
-- real shops. That skew matters for the indexing exercises.
INSERT INTO orders (id, customer_id, status, total_cents, created_at, updated_at)
SELECT n,
       1 + FLOOR(POW((CRC32(CONCAT('oc', n)) % 100000) / 100000, 3) * 20000),
       CASE WHEN CRC32(CONCAT('os', n)) % 100 < 3  THEN 'pending'
            WHEN CRC32(CONCAT('os', n)) % 100 < 8  THEN 'cancelled'
            WHEN CRC32(CONCAT('os', n)) % 100 < 10 THEN 'refunded'
            WHEN CRC32(CONCAT('os', n)) % 100 < 25 THEN 'paid'
            WHEN CRC32(CONCAT('os', n)) % 100 < 40 THEN 'shipped'
            ELSE 'delivered' END,
       0,
       TIMESTAMP('2024-01-01') + INTERVAL (n * 315) SECOND
                               + INTERVAL (CRC32(CONCAT('ot', n)) % 300) SECOND,
       TIMESTAMP('2024-01-01') + INTERVAL (n * 315) SECOND
                               + INTERVAL (CRC32(CONCAT('ot', n)) % 300 + 3600) SECOND
FROM _seq WHERE n BETWEEN 1 AND 200000;

-- 1 to 4 lines per order.
INSERT INTO order_items (order_id, line_no, product_id, quantity, price_cents)
SELECT o.id, l.n,
       1 + CRC32(CONCAT('ip', o.id, '-', l.n)) % 1000,
       1 + CRC32(CONCAT('iq', o.id, '-', l.n)) % 3,
       0
FROM orders o
JOIN _seq l ON l.n BETWEEN 1 AND 1 + CRC32(CONCAT('il', o.id)) % 4;

UPDATE order_items i JOIN products p ON p.id = i.product_id
SET i.price_cents = p.price_cents;

UPDATE orders o
JOIN (SELECT order_id, SUM(quantity * price_cents) AS total
      FROM order_items GROUP BY order_id) t ON t.order_id = o.id
SET o.total_cents = t.total;

-- One payment per order that got past 'pending'.
INSERT INTO payments (order_id, method, amount_cents, status, created_at)
SELECT o.id,
       ELT(1 + CRC32(CONCAT('pm', o.id)) % 3, 'card','bank_transfer','wallet'),
       o.total_cents,
       CASE o.status WHEN 'cancelled' THEN 'failed'
                     WHEN 'refunded'  THEN 'refunded'
                     ELSE 'captured' END,
       o.created_at + INTERVAL 2 MINUTE
FROM orders o
WHERE o.status <> 'pending'
ORDER BY o.id;

DROP TABLE _seq;
DROP TABLE _digits;

SET SESSION foreign_key_checks = 1;
SET SESSION unique_checks = 1;
ANALYZE TABLE customers, products, inventory, orders, order_items, payments;
