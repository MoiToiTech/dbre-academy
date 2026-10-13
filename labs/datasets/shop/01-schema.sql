-- shop: a small, entirely synthetic e-commerce schema used by every lab.
-- No row is derived from real customer or employer data.

DROP DATABASE IF EXISTS shop;
CREATE DATABASE shop CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE shop;

CREATE TABLE customers (
  id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  email        VARCHAR(255)  NOT NULL,
  full_name    VARCHAR(100)  NOT NULL,
  country_code CHAR(2)       NOT NULL,
  status       ENUM('active','suspended','closed') NOT NULL DEFAULT 'active',
  created_at   DATETIME      NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_customers_email (email)
) ENGINE=InnoDB;

CREATE TABLE products (
  id           INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  sku          VARCHAR(32)   NOT NULL,
  name         VARCHAR(200)  NOT NULL,
  category     VARCHAR(50)   NOT NULL,
  price_cents  INT UNSIGNED  NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_products_sku (sku),
  KEY idx_products_category (category)
) ENGINE=InnoDB;

CREATE TABLE inventory (
  product_id   INT UNSIGNED  NOT NULL,
  warehouse    CHAR(3)       NOT NULL,
  on_hand      INT           NOT NULL,
  reserved     INT           NOT NULL DEFAULT 0,
  updated_at   DATETIME      NOT NULL,
  PRIMARY KEY (product_id, warehouse),
  CONSTRAINT fk_inventory_product FOREIGN KEY (product_id) REFERENCES products (id)
) ENGINE=InnoDB;

CREATE TABLE orders (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  customer_id  INT UNSIGNED  NOT NULL,
  status       ENUM('pending','paid','shipped','delivered','cancelled','refunded') NOT NULL,
  total_cents  INT UNSIGNED  NOT NULL,
  created_at   DATETIME      NOT NULL,
  updated_at   DATETIME      NOT NULL,
  PRIMARY KEY (id),
  KEY idx_orders_customer (customer_id),
  CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES customers (id)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  order_id     BIGINT UNSIGNED NOT NULL,
  line_no      SMALLINT UNSIGNED NOT NULL,
  product_id   INT UNSIGNED  NOT NULL,
  quantity     SMALLINT UNSIGNED NOT NULL,
  price_cents  INT UNSIGNED  NOT NULL,
  PRIMARY KEY (order_id, line_no),
  KEY idx_order_items_product (product_id),
  CONSTRAINT fk_items_order   FOREIGN KEY (order_id)   REFERENCES orders (id),
  CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products (id)
) ENGINE=InnoDB;

CREATE TABLE payments (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  order_id     BIGINT UNSIGNED NOT NULL,
  method       ENUM('card','bank_transfer','wallet') NOT NULL,
  amount_cents INT UNSIGNED  NOT NULL,
  status       ENUM('authorized','captured','failed','refunded') NOT NULL,
  created_at   DATETIME      NOT NULL,
  PRIMARY KEY (id),
  KEY idx_payments_order (order_id),
  CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders (id)
) ENGINE=InnoDB;
