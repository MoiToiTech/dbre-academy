-- Content fingerprint of the shop schema: row count plus an order-independent
-- checksum per table. Two servers with identical data print identical rows.
-- Used by ./lab fingerprint, the backup/restore exercises and the CI tests.
-- (CHECKSUM TABLE would also work, but its value depends on row format and
-- server version; this does not.)
SELECT 'customers' AS tbl, COUNT(*) AS row_count,
       SUM(CRC32(CONCAT_WS('|', id, email, full_name, country_code, status, created_at))) AS checksum
  FROM shop.customers
UNION ALL
SELECT 'products', COUNT(*),
       SUM(CRC32(CONCAT_WS('|', id, sku, name, category, price_cents)))
  FROM shop.products
UNION ALL
SELECT 'inventory', COUNT(*),
       SUM(CRC32(CONCAT_WS('|', product_id, warehouse, on_hand, reserved, updated_at)))
  FROM shop.inventory
UNION ALL
SELECT 'orders', COUNT(*),
       SUM(CRC32(CONCAT_WS('|', id, customer_id, status, total_cents, created_at, updated_at)))
  FROM shop.orders
UNION ALL
SELECT 'order_items', COUNT(*),
       SUM(CRC32(CONCAT_WS('|', order_id, line_no, product_id, quantity, price_cents)))
  FROM shop.order_items
UNION ALL
SELECT 'payments', COUNT(*),
       SUM(CRC32(CONCAT_WS('|', id, order_id, method, amount_cents, status, created_at)))
  FROM shop.payments;
