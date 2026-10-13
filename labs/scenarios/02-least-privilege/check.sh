#!/usr/bin/env bash
. "$LAB_DIR/scripts/lib.sh"

echo "Checking 02-least-privilege"

if [ "$(sqlv primary "SELECT COUNT(*) FROM mysql.user WHERE user = 'report' AND host = '%'")" != "1" ]; then
  fail "report@'%' does not exist"
  hint "keep the account and its password; run the setup again if you dropped it"
  check_result; exit
fi

# --- The role ---------------------------------------------------------------
expect "role reporting_ro exists" \
  "$(sqlv primary "SELECT COUNT(*) FROM mysql.user WHERE user = 'reporting_ro' AND host = '%'")" "1"
expect "reporting_ro holds exactly SELECT on shop.*" \
  "$(sqlv primary "SELECT CONCAT_WS(',',
     (SELECT GROUP_CONCAT(PRIVILEGE_TYPE) FROM information_schema.SCHEMA_PRIVILEGES
       WHERE GRANTEE = \"'reporting_ro'@'%'\"),
     (SELECT GROUP_CONCAT(DISTINCT TABLE_SCHEMA) FROM information_schema.SCHEMA_PRIVILEGES
       WHERE GRANTEE = \"'reporting_ro'@'%'\"))")" "SELECT,shop"
expect "reporting_ro has no global, table or column privileges" \
  "$(sqlv primary "SELECT
     (SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES
       WHERE GRANTEE = \"'reporting_ro'@'%'\" AND PRIVILEGE_TYPE <> 'USAGE')
   + (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES  WHERE GRANTEE = \"'reporting_ro'@'%'\")
   + (SELECT COUNT(*) FROM information_schema.COLUMN_PRIVILEGES WHERE GRANTEE = \"'reporting_ro'@'%'\")")" "0"

# --- The account ------------------------------------------------------------
direct="$(sqlv primary "SELECT
   (SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES
     WHERE GRANTEE = \"'report'@'%'\" AND PRIVILEGE_TYPE <> 'USAGE')
 + (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE = \"'report'@'%'\")
 + (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES  WHERE GRANTEE = \"'report'@'%'\")
 + (SELECT COUNT(*) FROM information_schema.COLUMN_PRIVILEGES WHERE GRANTEE = \"'report'@'%'\")")"
expect "report@'%' has no privileges of its own (only through the role)" "$direct" "0"
[ "$direct" = "0" ] || hint "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'report'@'%'"
expect "reporting_ro is granted to report@'%'" \
  "$(sqlv primary "SELECT COUNT(*) FROM mysql.role_edges
                   WHERE FROM_USER = 'reporting_ro' AND FROM_HOST = '%'
                     AND TO_USER = 'report' AND TO_HOST = '%'")" "1"
expect "reporting_ro is a default role of report@'%'" \
  "$(sqlv primary "SELECT COUNT(*) FROM mysql.default_roles
                   WHERE USER = 'report' AND HOST = '%'
                     AND DEFAULT_ROLE_USER = 'reporting_ro' AND DEFAULT_ROLE_HOST = '%'")" "1"
[ "$(sqlv primary "SELECT COUNT(*) FROM mysql.default_roles WHERE USER = 'report'")" = "1" ] \
  || hint "SET DEFAULT ROLE reporting_ro TO 'report'@'%' (otherwise the role is inactive at login)"

ssl="$(sqlv primary "SELECT ssl_type FROM mysql.user WHERE user = 'report' AND host = '%'")"
case "$ssl" in
  ANY|X509|SPECIFIED) pass "report@'%' requires TLS (ssl_type $ssl)" ;;
  *) fail "report@'%' does not require TLS"; hint "ALTER USER ... REQUIRE SSL" ;;
esac
expect "report@'%' authenticates with caching_sha2_password" \
  "$(sqlv primary "SELECT plugin FROM mysql.user WHERE user = 'report' AND host = '%'")" "caching_sha2_password"
lock="$(sqlv primary "SELECT CONCAT(
          IFNULL(User_attributes->>'$.Password_locking.failed_login_attempts', 0), '/',
          IFNULL(User_attributes->>'$.Password_locking.password_lock_time_days', 0))
        FROM mysql.user WHERE user = 'report' AND host = '%'")"
attempts="${lock%/*}"; locktime="${lock#*/}"
if [ "$attempts" -ge 3 ] && [ "$attempts" -le 10 ] && [ "$locktime" != "0" ]; then
  pass "failed-login tracking is on ($attempts attempts, lock time $locktime)"
else
  fail "failed-login tracking: FAILED_LOGIN_ATTEMPTS $attempts, PASSWORD_LOCK_TIME $locktime"
  hint "ALTER USER ... FAILED_LOGIN_ATTEMPTS 5 PASSWORD_LOCK_TIME 1 (3 to 10 attempts)"
fi

# --- Behaviour: log in as report over TCP ------------------------------------
# --get-server-public-key lets caching_sha2_password exchange the password
# over a plain connection (RSA), so a refusal below comes from REQUIRE SSL.
as_report() { # as_report <ssl-mode> <sql>
  dc exec -T -e MYSQL_PWD=dbre-lab-report primary \
    mysql -h127.0.0.1 -ureport --ssl-mode="$1" --get-server-public-key -N -B -e "$2" 2>&1
}
if as_report DISABLED "SELECT 1" >/dev/null; then
  fail "report can log in without TLS"
else
  pass "a connection without TLS is refused"
fi
expect "report can read shop.orders over TLS" \
  "$(as_report REQUIRED "SELECT COUNT(*) FROM shop.orders" | tail -1)" "200000"
out="$(as_report REQUIRED "UPDATE shop.orders SET status = status WHERE id = 1" || true)"
case "$out" in
  *1142*) pass "report cannot write to shop (ERROR 1142)" ;;
  *) fail "an UPDATE on shop.orders as report was not denied: $out" ;;
esac
out="$(as_report REQUIRED "SELECT COUNT(*) FROM mysql.user" || true)"
case "$out" in
  *1142*) pass "report cannot read the mysql schema" ;;
  *) fail "report can read mysql.user: $out" ;;
esac

check_result
