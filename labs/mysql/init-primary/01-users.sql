-- Lab accounts on the primary. Runs once, on an empty data directory.
-- These passwords are lab-only. In production, generate secrets and keep
-- them out of version control.

-- Replication account: may only read the binary log stream.
CREATE USER 'repl'@'%' IDENTIFIED BY 'dbre-lab-repl';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

-- Application account: data changes on the shop schema, nothing else.
CREATE USER 'app'@'%' IDENTIFIED BY 'dbre-lab-app';
GRANT SELECT, INSERT, UPDATE, DELETE ON shop.* TO 'app'@'%';

-- Monitoring account for mysqld_exporter, as its README recommends.
CREATE USER 'exporter'@'%' IDENTIFIED BY 'dbre-lab-exporter' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'%';
