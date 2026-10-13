#!/usr/bin/env bash
# Reference solution. Try the exercise first.
. "$LAB_DIR/scripts/lib.sh"

sql primary <<'SQL'
CREATE ROLE 'reporting_ro';
GRANT SELECT ON shop.* TO 'reporting_ro';

REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'report'@'%';
GRANT 'reporting_ro' TO 'report'@'%';
SET DEFAULT ROLE 'reporting_ro' TO 'report'@'%';
ALTER USER 'report'@'%'
  REQUIRE SSL
  FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1;
SQL
