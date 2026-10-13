SELECT id, customer_id, total_cents, created_at
  FROM shop.orders
 WHERE status = 'pending'
   AND created_at >= '2025-12-01'
 ORDER BY created_at
