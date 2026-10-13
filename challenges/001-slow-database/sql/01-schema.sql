-- The shop's order database. Orders are written by checkout; every order
-- queues an e-mail in the transactional outbox, and the outbox workers send
-- them.
CREATE DATABASE IF NOT EXISTS shop;
USE shop;

CREATE TABLE customers (
  id          INT UNSIGNED NOT NULL PRIMARY KEY,
  email       VARCHAR(120) NOT NULL,
  country     CHAR(2)      NOT NULL,
  created_at  DATETIME     NOT NULL,
  UNIQUE KEY uk_email (email)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id           INT UNSIGNED  NOT NULL PRIMARY KEY,
  customer_id  INT UNSIGNED  NOT NULL,
  status       ENUM('paid','shipped','delivered','refunded') NOT NULL,
  total        DECIMAL(10,2) NOT NULL,
  created_at   DATETIME      NOT NULL,
  KEY idx_customer (customer_id),
  KEY idx_created (created_at),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
) ENGINE=InnoDB;

-- Transactional outbox. Producers insert 'pending' rows; workers claim the
-- oldest pending rows and mark them 'sent'.
CREATE TABLE outbox (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  order_id    INT UNSIGNED    NOT NULL,
  kind        VARCHAR(32)     NOT NULL,
  payload     JSON            NOT NULL,
  status      ENUM('pending','sent') NOT NULL DEFAULT 'pending',
  created_at  DATETIME(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  sent_at     DATETIME(3)     NULL,
  KEY idx_status_id (status, id)
) ENGINE=InnoDB;

CREATE USER 'app'@'%' IDENTIFIED BY 'app-local-only';
GRANT SELECT, INSERT, UPDATE ON shop.* TO 'app'@'%';
CREATE USER 'analytics'@'%' IDENTIFIED BY 'analytics-local-only';
GRANT SELECT ON shop.* TO 'analytics'@'%';

-- Lab bookkeeping, not part of the shop.
CREATE DATABASE IF NOT EXISTS challenge;
CREATE TABLE challenge.run (
  k VARCHAR(32) NOT NULL PRIMARY KEY,
  v VARCHAR(64) NOT NULL
) ENGINE=InnoDB;
