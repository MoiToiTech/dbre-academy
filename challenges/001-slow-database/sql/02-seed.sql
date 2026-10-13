-- Deterministic synthetic data: the same rows on every machine and every
-- reset. No real people, no real shop.
USE shop;
SET SESSION cte_max_recursion_depth = 100000;

INSERT INTO customers (id, email, country, created_at)
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 5000)
SELECT n,
       CONCAT('customer', n, '@example.com'),
       ELT(1 + n % 6, 'EE', 'FI', 'LV', 'LT', 'SE', 'DE'),
       '2025-01-01' + INTERVAL (n * 97) % 365 DAY
FROM s;

INSERT INTO orders (id, customer_id, status, total, created_at)
WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 20000)
SELECT n,
       1 + (n * 7919) % 5000,
       ELT(1 + (n * 31) % 10, 'paid', 'shipped', 'delivered', 'delivered', 'delivered',
           'delivered', 'shipped', 'delivered', 'delivered', 'refunded'),
       ROUND(5 + ((n * 2654435761) % 30000) / 100, 2),
       '2026-01-01' + INTERVAL (n * 1301) % (280 * 86400) SECOND
FROM s;
