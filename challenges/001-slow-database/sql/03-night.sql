-- Replays the night before the incident: checkout keeps queueing
-- confirmation e-mails and the workers keep sending them, ten at a time, each
-- batch in its own transaction — exactly what the order service does, only
-- faster. Called by ./challenge start with the number of batches.
DROP PROCEDURE IF EXISTS challenge.replay_night;
DELIMITER //
CREATE PROCEDURE challenge.replay_night(IN batches INT)
SQL SECURITY INVOKER
BEGIN
  DECLARE i INT DEFAULT 0;
  DECLARE first_id BIGINT UNSIGNED;
  DECLARE ts DATETIME(3);
  WHILE i < batches DO
    -- One batch every half second, ending now: the night, compressed.
    SET ts = NOW(3) - INTERVAL ((batches - i) * 500000) MICROSECOND;
    INSERT INTO shop.outbox (order_id, kind, payload, created_at)
    SELECT 1 + ((i * 10 + n) % 20000), 'order_confirmation',
           JSON_OBJECT('order_id', 1 + ((i * 10 + n) % 20000), 'template', 'confirmation_v3'), ts
    FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d;
    SET first_id = LAST_INSERT_ID();
    UPDATE shop.outbox SET status = 'sent', sent_at = ts + INTERVAL 150000 MICROSECOND
     WHERE id BETWEEN first_id AND first_id + 9;
    SET i = i + 1;
  END WHILE;
END //
DELIMITER ;
