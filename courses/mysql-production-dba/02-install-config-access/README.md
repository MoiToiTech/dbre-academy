# Module 2 — Installation, configuration and secure access

`time: ~70 min` · `lab: ./lab scenario setup 02-config-drift`, `./lab scenario setup 02-least-privilege` · `level: fundamentals`

Two questions come up on every server you inherit: *what is it actually
running with?* and *who can get in, and what can they do?* The first is
harder than it looks, because a MySQL setting can come from several option
files, from the command line, from a runtime `SET`, or from a file the
server writes itself. The second is where most avoidable incidents start:
an application connected as `root`, a BI tool with `ALL PRIVILEGES`, a
password sent in clear over the network. This module shows how a MySQL 8.4
server is installed and initialised, where every setting comes from, and
how to give each client exactly the access it needs.

## Learning objectives

By the end of this module you can:

- say what the MySQL 8.4 LTS track means for upgrades, and which 8.0
  habits no longer work;
- compare the installation options and explain what data directory
  initialisation does, using the lab's Docker entrypoint as the example;
- find which option file, if any, set a variable, and predict which value
  wins;
- choose correctly between `SET GLOBAL`, `SET PERSIST`, `SET PERSIST_ONLY`
  and an option file edit, and undo each one;
- create accounts and roles with least privilege, require TLS, and turn on
  failed-login tracking, password expiry and password validation.

## Prerequisites

- [Module 1](../01-architecture/README.md), and the lab running (`./lab up`).
- Commands run from `labs/`. As in Module 1,
  `./lab exec primary <command>` runs one command inside the primary's
  container, and `docker compose exec -T -e NAME=value primary <command>` does
  the same with an environment variable set.

## MySQL 8.4 is an LTS release

MySQL now ships on two tracks
([MySQL Releases: Innovation and LTS](https://dev.mysql.com/doc/refman/8.4/en/mysql-releases.html)):

- **LTS** (8.4.x): only necessary fixes. "There are no removals within an
  LTS release"; features are added or removed only in its first release,
  8.4.0. Support follows Oracle's Lifetime Support Policy: 5 years of
  premier and 3 years of extended support.
- **Innovation** (9.x): new features, behaviour changes and removals from
  one release to the next, for teams that upgrade often.

For production, that means: pick the LTS, take its patch releases, and plan
the next major move (8.4 to the next LTS) as a project. The lab runs 8.4.11.

8.4.0 was where the 8.0-era deprecations were finally removed
([What Is New in MySQL 8.4 since MySQL 8.0](https://dev.mysql.com/doc/refman/8.4/en/mysql-nutshell.html)).
The ones you will trip over first:

| Removed or changed in 8.4 | Use instead |
|---|---|
| `mysql_native_password` enabled by default | `caching_sha2_password` (native is disabled; see below) |
| `mysqlpump` | `mysqldump` or MySQL Shell dump utilities |
| `mysql_upgrade` | Nothing: the server upgrades the data dictionary and system tables itself at startup ([manual](https://dev.mysql.com/doc/refman/8.4/en/upgrading-what-is-upgraded.html)) |
| `CHANGE MASTER TO`, `START SLAVE`, `SHOW SLAVE STATUS`, `SHOW MASTER STATUS` … | `CHANGE REPLICATION SOURCE TO`, `START REPLICA`, `SHOW REPLICA STATUS`, `SHOW BINARY LOG STATUS` … |

Old runbooks and monitoring scripts that still say `SHOW SLAVE STATUS` fail
on 8.4 with a syntax error. Grep for them before you upgrade.

## Installation options

| Option | Typical use | What you manage |
|---|---|---|
| OS packages from Oracle's repositories (yum/dnf, APT) | Most VM and bare-metal installs | systemd unit, `/etc/my.cnf`, upgrades via the package manager |
| Generic Linux tarball | Several versions side by side, no root access, custom layouts | Everything: user, directories, init script |
| Container image (`mysql:8.4`) | Kubernetes, CI, labs like this one | Volumes, configuration mounts, entrypoint behaviour |

([Installing MySQL](https://dev.mysql.com/doc/refman/8.4/en/installing.html),
[Using the Yum Repository](https://dev.mysql.com/doc/refman/8.4/en/linux-installation-yum-repo.html),
[Installing from Generic Binaries](https://dev.mysql.com/doc/refman/8.4/en/binary-installation.html),
[Deploying MySQL on Linux with Docker](https://dev.mysql.com/doc/refman/8.4/en/docker-mysql-getting-started.html))

Whichever you choose, the first start of a server on an empty data
directory runs **initialisation**: `mysqld --initialize` or
`--initialize-insecure`
([Initializing the Data Directory](https://dev.mysql.com/doc/refman/8.4/en/data-directory-initialization.html)).
It creates the `mysql` system schema (data dictionary, grant tables), the
InnoDB system and undo tablespaces and redo log, and the `'root'@'localhost'`
account. `--initialize` gives root a random password, written to the error
log; `--initialize-insecure` creates root with **no** password. TLS and RSA
key files are generated in the data directory at startup if missing
(`auto_generate_certs`,
[Creating SSL and RSA Certificates and Keys](https://dev.mysql.com/doc/refman/8.4/en/creating-ssl-rsa-files-using-mysql.html)).

The installers add their own steps. An RPM install from Oracle's repository
also installs and enables the `validate_password` component on first start
and puts the temporary root password in `/var/log/mysqld.log`
([Using the Yum Repository](https://dev.mysql.com/doc/refman/8.4/en/linux-installation-yum-repo.html)).
The Docker image does neither, as you can see in the lab.

### What the Docker entrypoint did in this lab

On a freshly created lab, `./lab logs primary` starts with the image's
entrypoint initialising the data directory. Trimmed:

```text
[Entrypoint]: Initializing database files
[Server] /usr/sbin/mysqld (mysqld 8.4.11) initializing of server in progress as process 80
[Server] root@localhost is created with an empty password ! Please consider
         switching off the --initialize-insecure option.
[Entrypoint]: Database files initialized
[Entrypoint]: Starting temporary server
[Server] /usr/sbin/mysqld: ready for connections. ... socket: '/var/run/mysqld/mysqld.sock'  port: 0
[Entrypoint]: Temporary server started.
[Entrypoint]: /usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/01-users.sql
[Entrypoint]: Stopping temporary server
[Entrypoint]: Temporary server stopped
[Entrypoint]: MySQL init process done. Ready for start up.
[Server] /usr/sbin/mysqld: ready for connections. ... port: 3306
```

The sequence is:

1. `mysqld --initialize-insecure`: root without a password.
2. Start a **temporary server** with networking off (`port: 0`), reachable
   only over the socket inside the container.
3. Over that socket, set root's password from `MYSQL_ROOT_PASSWORD` and
   create `root@'%'` because the lab sets `MYSQL_ROOT_HOST=%` (this step is
   not logged; `mysql.user` below shows the result), then run every file in
   `/docker-entrypoint-initdb.d/` — here `labs/mysql/init-primary/01-users.sql`,
   which creates `repl`, `app` and `exporter`.
4. Stop the temporary server and start the real one on port 3306.

The passwordless window exists only while nothing can reach the server over
the network. It all happens once: on a data directory that is not empty, the
entrypoint skips straight to step 4. That is also why changing
`MYSQL_ROOT_PASSWORD` on an existing volume does nothing.

The data directory remembers its installation history in a file added in
8.4:

```bash test
./lab exec primary cat /var/lib/mysql/mysql_upgrade_history
echo
```

```text
{"file_format":"1","upgrade_history":[{"date":"2026-10-13 10:27:59","version":"8.4.11","maturity":"LTS","initialize":true}]}
```

## Where settings come from

### Option files and precedence

`mysqld --verbose --help` prints which files the server reads, in order:

```bash test
./lab exec primary mysqld --verbose --help 2>/dev/null \
  | sed -n '/^Default options/,/^The following groups/p'
```

```text
Default options are read from the following files in the given order:
/etc/my.cnf /etc/mysql/my.cnf /usr/etc/my.cnf ~/.my.cnf
The following groups are read: mysql_cluster mysqld server mysqld-8.4
```

The lab's settings are in none of those files directly. The image's
`/etc/my.cnf` ends with `!includedir /etc/mysql/conf.d/`, and the lab mounts
`labs/mysql/primary.cnf` there as `dbre.cnf`. To see the options the server
would start with, after all files and includes are merged, ask
`my_print_defaults` (or `mysqld --print-defaults`):

```bash test
./lab exec primary my_print_defaults mysqld
```

```text
--host-cache-size=0
--skip-name-resolve
--datadir=/var/lib/mysql
--socket=/var/run/mysqld/mysqld.sock
--secure-file-priv=/var/lib/mysql-files
--user=mysql
--pid-file=/var/run/mysqld/mysqld.pid
--server_id=1
--report_host=primary
--log_bin=binlog
...
--max_connections=200
--skip_name_resolve=ON
--local_infile=OFF
```

The rules
([Using Option Files](https://dev.mysql.com/doc/refman/8.4/en/option-files.html)):

- Files are read in the order above; `!include` and `!includedir` read
  further files at that point.
- If an option appears more than once, **the last instance wins** (with one
  exception: for `mysqld`, the first `--user` wins).
- Command-line options are processed after all option files.
- `mysqld-auto.cnf` in the data directory, written by `SET PERSIST`, is
  read last of all.

`skip-name-resolve` appears twice above: once in `/etc/my.cnf` and once in
`dbre.cnf`. `performance_schema.variables_info` tells you which one the
server actually used, and for every variable whether it came from a file, the
command line, a runtime `SET`, or the compiled-in default
([variables_info](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-variables-info-table.html)):

```sql test
SELECT VARIABLE_NAME, VARIABLE_SOURCE, VARIABLE_PATH
FROM performance_schema.variables_info
WHERE VARIABLE_NAME IN ('datadir', 'innodb_page_size', 'long_query_time',
                        'max_connections', 'skip_name_resolve');
```

```text
+-------------------+-----------------+----------------------------+
| VARIABLE_NAME     | VARIABLE_SOURCE | VARIABLE_PATH              |
+-------------------+-----------------+----------------------------+
| datadir           | GLOBAL          | /etc/my.cnf                |
| innodb_page_size  | COMPILED        |                            |
| long_query_time   | GLOBAL          | /etc/mysql/conf.d/dbre.cnf |
| max_connections   | GLOBAL          | /etc/mysql/conf.d/dbre.cnf |
| skip_name_resolve | GLOBAL          | /etc/mysql/conf.d/dbre.cnf |
+-------------------+-----------------+----------------------------+
```

`GLOBAL` here means "a global option file", not the variable's scope.
`DYNAMIC` means it was changed at runtime with `SET`; `PERSISTED` means it
came from `mysqld-auto.cnf`.

### Dynamic and static variables

A **dynamic** variable can be changed while the server runs; a **static**
(read-only) one is fixed at startup
([Dynamic System Variables](https://dev.mysql.com/doc/refman/8.4/en/dynamic-system-variables.html)):

```sql test expect-error
SET GLOBAL skip_name_resolve = OFF;
```

```text
ERROR 1238 (HY000) at line 1: Variable 'skip_name_resolve' is a read only variable
```

Dynamic variables often have two scopes. `SET GLOBAL` changes the global
value, which new sessions copy when they connect. It does **not** change
sessions that are already open — including the one you typed it in:

```sql test
SET GLOBAL long_query_time = 5;
SELECT @@GLOBAL.long_query_time, @@SESSION.long_query_time;
SET GLOBAL long_query_time = 1;
```

```text
+--------------------------+---------------------------+
| @@GLOBAL.long_query_time | @@SESSION.long_query_time |
+--------------------------+---------------------------+
|                 5.000000 |                  1.000000 |
+--------------------------+---------------------------+
```

An application with a connection pool keeps its old session values until
its connections are recycled. "I changed it and nothing happened" is often
this.

### SET GLOBAL, SET PERSIST, SET PERSIST_ONLY

| Statement | Changes now | Survives restart | Works for static variables |
|---|---|---|---|
| `SET GLOBAL` | Yes | No | No |
| `SET PERSIST` | Yes | Yes, via `mysqld-auto.cnf` | No |
| `SET PERSIST_ONLY` | No | Yes, via `mysqld-auto.cnf` | Yes |
| Edit an option file | No | Yes | Yes |

`RESET PERSIST name` removes a setting from `mysqld-auto.cnf`. It does not
change the running value.
([Persisted System Variables](https://dev.mysql.com/doc/refman/8.4/en/persisted-system-variables.html),
[SET Syntax for Variable Assignment](https://dev.mysql.com/doc/refman/8.4/en/set-variable.html))

Watch a persisted value survive a restart and override the option file.
This restarts the primary, which takes about 20 seconds:

```bash test
./lab sql -e "SET PERSIST max_connections = 300"
./lab exec primary cat /var/lib/mysql/mysqld-auto.cnf
echo

docker compose restart primary >/dev/null 2>&1
./lab up >/dev/null 2>&1   # waits for health and restarts replication

./lab sql --table -e "
  SELECT VARIABLE_NAME, VARIABLE_SOURCE, VARIABLE_PATH
  FROM performance_schema.variables_info
  WHERE VARIABLE_NAME = 'max_connections';
  SELECT @@max_connections"
```

```text
{"Version": 2, "mysql_dynamic_parse_early_variables": {"max_connections":
 {"Value": "300", "Metadata": {"Host": "localhost", "User": "root", ...}}}}
+-----------------+-----------------+--------------------------------+
| VARIABLE_NAME   | VARIABLE_SOURCE | VARIABLE_PATH                  |
+-----------------+-----------------+--------------------------------+
| max_connections | PERSISTED       | /var/lib/mysql/mysqld-auto.cnf |
+-----------------+-----------------+--------------------------------+
+-------------------+
| @@max_connections |
+-------------------+
|               300 |
+-------------------+
```

`dbre.cnf` still says 200, and `my_print_defaults` still prints 200. Only
`variables_info` tells the truth. Undo it — both halves:

```sql test
RESET PERSIST max_connections;
SET GLOBAL max_connections = 200;
SELECT COUNT(*) AS persisted FROM performance_schema.persisted_variables;
```

```text
+-----------+
| persisted |
+-----------+
|         0 |
+-----------+
```

`SET PERSIST` is useful: a change made during an incident that must not
silently revert at the next restart. The trap is that the configuration is
now in two places, and the option file under configuration management no
longer describes the server. Pick one source of truth per server. If it is
your option files, treat every row in `performance_schema.persisted_variables`
as drift to be folded back into the files and reset.

<!-- founder-review: a real story about configuration drift between
my.cnf and runtime/persisted values (and what it cost after a restart or
failover) would help here -->

## Secure access

### Accounts are user@host

A MySQL account is a user name **and** a host pattern. `'app'@'%'` and
`'app'@'10.0.%'` are different accounts with different passwords and
privileges
([Specifying Account Names](https://dev.mysql.com/doc/refman/8.4/en/account-names.html)).
When a client connects, the server sorts accounts most-specific host first
and uses the first that matches
([Access Control, Stage 1](https://dev.mysql.com/doc/refman/8.4/en/connection-access.html)).
`USER()` is who the client said it was and where from; `CURRENT_USER()` is
the account it matched.

Host patterns with the `%` and `_` wildcards (`'10.0.%'`, even `'%'`) still
work in 8.4 and print no warning, but the manual marks them deprecated. For
a subnet, prefer netmask notation: `'app'@'10.0.0.0/255.255.0.0'`.

The lab runs with `skip_name_resolve = ON`: the server never does DNS
lookups, so it matches on IP addresses only, and accounts defined with host
names cannot be used
([DNS Lookups and the Host Cache](https://dev.mysql.com/doc/refman/8.4/en/host-cache.html)).
That removes DNS from the login path — a slow or broken resolver can no
longer stall every new connection — at the price of writing host patterns
as addresses or subnets.

```sql test
SELECT user, host, plugin, account_locked
FROM mysql.user
ORDER BY user, host;
```

```text
+------------------+-----------+-----------------------+----------------+
| user             | host      | plugin                | account_locked |
+------------------+-----------+-----------------------+----------------+
| app              | %         | caching_sha2_password | N              |
| exporter         | %         | caching_sha2_password | N              |
| mysql.infoschema | localhost | caching_sha2_password | Y              |
| mysql.session    | localhost | caching_sha2_password | Y              |
| mysql.sys        | localhost | caching_sha2_password | Y              |
| repl             | %         | caching_sha2_password | N              |
| root             | %         | caching_sha2_password | N              |
| root             | localhost | caching_sha2_password | N              |
+------------------+-----------+-----------------------+----------------+
```

The three `mysql.*` accounts are reserved, locked accounts the server uses
internally. `root@'%'` — root from anywhere — exists only because this is a
lab bound to 127.0.0.1. Do not create it in production.

### Least privilege, and why applications never use root

Each lab account has only what its job needs:

```sql test
SHOW GRANTS FOR 'app'@'%';
SHOW GRANTS FOR 'exporter'@'%';
```

```text
+---------------------------------------------------------------+
| Grants for app@%                                              |
+---------------------------------------------------------------+
| GRANT USAGE ON *.* TO `app`@`%`                               |
| GRANT SELECT, INSERT, UPDATE, DELETE ON `shop`.* TO `app`@`%` |
+---------------------------------------------------------------+
+--------------------------------------------------------------------+
| Grants for exporter@%                                              |
+--------------------------------------------------------------------+
| GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO `exporter`@`%` |
+--------------------------------------------------------------------+
```

`USAGE` means "no privileges"; every account has it. `app` can change data
in `shop` but cannot `DROP` a table, read `mysql.user` or change a setting.

An application connected as root, or any account with administrative
privileges, defeats several safety mechanisms at once. With
`CONNECTION_ADMIN` (which root has):

- `read_only` does not stop you: the server "permits no client updates
  except from users who have the `CONNECTION_ADMIN` privilege". An
  application pointed at a replica by mistake writes to it. Only
  `super_read_only` stops root
  ([read_only](https://dev.mysql.com/doc/refman/8.4/en/server-system-variables.html)).
- `init_connect` is not executed for you.
- You can use the one extra connection above `max_connections` that the
  server reserves for administrators — so when the application exhausts
  the connection limit, the DBA cannot get in to fix it
  ([Too many connections](https://dev.mysql.com/doc/refman/8.4/en/too-many-connections.html)).

And a SQL injection in the application becomes `DROP DATABASE`, or reading
every table on the server.

### Roles

A role is a named bundle of privileges that you grant to accounts
([Using Roles](https://dev.mysql.com/doc/refman/8.4/en/roles.html)). Grant
privileges to roles, and roles to accounts; then "what can the reporting
tools do?" has one answer in one place.

```sql test
CREATE ROLE 'shop_writer';
GRANT SELECT, INSERT, UPDATE, DELETE ON shop.* TO 'shop_writer';

CREATE USER 'lesson_app'@'10.0.0.0/255.255.0.0' IDENTIFIED BY 'Lesson-app-2026';
GRANT 'shop_writer' TO 'lesson_app'@'10.0.0.0/255.255.0.0';
SET DEFAULT ROLE 'shop_writer' TO 'lesson_app'@'10.0.0.0/255.255.0.0';

SHOW GRANTS FOR 'lesson_app'@'10.0.0.0/255.255.0.0';
SHOW GRANTS FOR 'lesson_app'@'10.0.0.0/255.255.0.0' USING 'shop_writer';
SELECT user, host, account_locked FROM mysql.user WHERE user = 'shop_writer';

DROP USER 'lesson_app'@'10.0.0.0/255.255.0.0';
DROP ROLE 'shop_writer';
```

```text
+----------------------------------------------------------------+
| Grants for lesson_app@10.0.0.0/255.255.0.0                     |
+----------------------------------------------------------------+
| GRANT USAGE ON *.* TO `lesson_app`@`10.0.0.0/255.255.0.0`      |
| GRANT `shop_writer`@`%` TO `lesson_app`@`10.0.0.0/255.255.0.0` |
+----------------------------------------------------------------+
+-----------------------------------------------------------------------------------------+
| Grants for lesson_app@10.0.0.0/255.255.0.0                                              |
+-----------------------------------------------------------------------------------------+
| GRANT USAGE ON *.* TO `lesson_app`@`10.0.0.0/255.255.0.0`                               |
| GRANT SELECT, INSERT, UPDATE, DELETE ON `shop`.* TO `lesson_app`@`10.0.0.0/255.255.0.0` |
| GRANT `shop_writer`@`%` TO `lesson_app`@`10.0.0.0/255.255.0.0`                          |
+-----------------------------------------------------------------------------------------+
+-------------+------+----------------+
| user        | host | account_locked |
+-------------+------+----------------+
| shop_writer | %    | Y              |
+-------------+------+----------------+
```

Two details catch people out:

- A granted role is **inactive** at login unless it is a default role (`SET
  DEFAULT ROLE`) or `activate_all_roles_on_login` is on. Without that, the
  account logs in with only `USAGE` and every query fails with "command
  denied".
- A role is stored as a locked account in `mysql.user`, so nobody can log in
  as it.

### Authentication: caching_sha2_password

Every lab account uses `caching_sha2_password`, the default. The older
`mysql_native_password` plugin has been deprecated since 8.0.34 and is
disabled in 8.4 unless you start the server with `mysql_native_password=ON`
([Native Pluggable Authentication](https://dev.mysql.com/doc/refman/8.4/en/native-pluggable-authentication.html)):

```sql test expect-error
CREATE USER 'legacy'@'%' IDENTIFIED WITH mysql_native_password BY 'x';
```

```text
ERROR 1524 (HY000) at line 1: Plugin 'mysql_native_password' is not loaded
```

Turning it back on is a migration crutch for old client libraries, not a
fix. `caching_sha2_password` needs either a TLS connection or an RSA key
exchange to send the password the first time
([Caching SHA-2 Pluggable Authentication](https://dev.mysql.com/doc/refman/8.4/en/caching-sha2-pluggable-authentication.html)),
which is one more reason to use TLS everywhere.

### TLS

The server generated a CA and certificates at initialisation (the `*.pem`
files from Module 1), so TLS works out of the box and clients use it by
default over TCP. Compare a TCP connection with a Unix socket connection:

```bash test
docker compose exec -T -e MYSQL_PWD=dbre-lab-app primary \
  mysql -uapp -h127.0.0.1 --table -e "SELECT USER(), CURRENT_USER();
    SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_version', 'Ssl_cipher')"
docker compose exec -T -e MYSQL_PWD=dbre-lab-app primary \
  mysql -uapp --table -e "SELECT USER(), CURRENT_USER();
    SHOW SESSION STATUS WHERE Variable_name IN ('Ssl_version', 'Ssl_cipher')"
```

```text
+---------------+----------------+
| USER()        | CURRENT_USER() |
+---------------+----------------+
| app@127.0.0.1 | app@%          |
+---------------+----------------+
+---------------+------------------------+
| Variable_name | Value                  |
+---------------+------------------------+
| Ssl_cipher    | TLS_AES_128_GCM_SHA256 |
| Ssl_version   | TLSv1.3                |
+---------------+------------------------+
+---------------+----------------+
| USER()        | CURRENT_USER() |
+---------------+----------------+
| app@localhost | app@%          |
+---------------+----------------+
+---------------+-------+
| Variable_name | Value |
+---------------+-------+
| Ssl_cipher    |       |
| Ssl_version   |       |
+---------------+-------+
```

"Used by default" is not "required": a client can still choose
`--ssl-mode=DISABLED`. There are two ways to require it
([Using Encrypted Connections](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html)):

- **Per account**: `CREATE USER ... REQUIRE SSL` (or `REQUIRE X509` for a
  client certificate). The account can then log in only over TLS — not even
  over the local socket.
- **Server-wide**: `require_secure_transport = ON` refuses every TCP
  connection without TLS. Socket connections count as secure and still
  work.

```bash test
./lab sql -e "SET GLOBAL require_secure_transport = ON"
docker compose exec -T -e MYSQL_PWD=dbre-lab-app primary \
  mysql -uapp -h127.0.0.1 --ssl-mode=DISABLED -e "SELECT 1" || true
docker compose exec -T -e MYSQL_PWD=dbre-lab-app primary \
  mysql -uapp -e "SELECT 'socket is fine' AS result"
./lab sql -e "SET GLOBAL require_secure_transport = OFF"
```

```text
ERROR 3159 (HY000): Connections using insecure transport are prohibited while --require_secure_transport=ON.
result
socket is fine
```

The lab's certificates are self-signed, so a client can encrypt but cannot
verify it is talking to the right server. In production, issue server
certificates from a CA your clients trust, and have clients connect with
`--ssl-mode=VERIFY_IDENTITY`; otherwise TLS protects against eavesdropping
but not against an impostor.

### Locking, failed logins and password expiry

```sql test
CREATE USER 'lesson_tmp'@'%' IDENTIFIED BY 'Lesson-pass-2026'
  FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1
  PASSWORD EXPIRE INTERVAL 90 DAY;

SELECT user, password_lifetime, account_locked, User_attributes
FROM mysql.user WHERE user = 'lesson_tmp'\G
```

```text
             user: lesson_tmp
password_lifetime: 90
   account_locked: N
  User_attributes: {"Password_locking": {"failed_login_attempts": 3, "password_lock_time_days": 1}}
```

Three wrong passwords lock the account for a day — and after that, even the
right password is refused until the lock expires or an administrator runs
`ALTER USER ... ACCOUNT UNLOCK`
([Password Management](https://dev.mysql.com/doc/refman/8.4/en/password-management.html)):

```bash test
for pw in wrong1 wrong2 wrong3 Lesson-pass-2026; do
  docker compose exec -T -e MYSQL_PWD="$pw" primary \
    mysql -ulesson_tmp -h127.0.0.1 -N -e "SELECT 'logged in'" || true
done
./lab sql -e "ALTER USER 'lesson_tmp'@'%' ACCOUNT UNLOCK"
docker compose exec -T -e MYSQL_PWD=Lesson-pass-2026 primary \
  mysql -ulesson_tmp -h127.0.0.1 -N -e "SELECT 'logged in'"
```

```text
ERROR 1045 (28000): Access denied for user 'lesson_tmp'@'127.0.0.1' (using password: YES)
ERROR 1045 (28000): Access denied for user 'lesson_tmp'@'127.0.0.1' (using password: YES)
ERROR 3955 (HY000): Access denied for user 'lesson_tmp'@'127.0.0.1'. Account is blocked
  for 1 day(s) (1 day(s) remaining) due to 3 consecutive failed logins.
ERROR 3955 (HY000): Access denied for user 'lesson_tmp'@'127.0.0.1'. Account is blocked
  for 1 day(s) (1 day(s) remaining) due to 3 consecutive failed logins.
logged in
```

Failed-login tracking is a brake on password guessing, and also a way for
an application with a stale password to lock itself out. Use it on human and
reporting accounts; think twice before turning it on for an application
account whose lockout would be an outage.

`ACCOUNT LOCK` is different: an administrative switch, for example to
disable an account before dropping it, and see who complains:

```bash test
./lab sql -e "ALTER USER 'lesson_tmp'@'%' ACCOUNT LOCK"
docker compose exec -T -e MYSQL_PWD=Lesson-pass-2026 primary \
  mysql -ulesson_tmp -h127.0.0.1 -e "SELECT 1" || true
./lab sql -e "DROP USER 'lesson_tmp'@'%'"
```

```text
ERROR 3118 (HY000): Access denied for user 'lesson_tmp'@'127.0.0.1'. Account is locked.
```

([Account Locking](https://dev.mysql.com/doc/refman/8.4/en/account-locking.html))

`PASSWORD EXPIRE INTERVAL 90 DAY` forces a password change every 90 days;
with an expired password the server either refuses the connection or lets
the client in only to set a new one
([Server Handling of Expired Passwords](https://dev.mysql.com/doc/refman/8.4/en/expired-password-handling.html)). The server-wide default is `default_password_lifetime`, 0 (never)
in the lab. For human accounts, expiry is a policy decision; for service
accounts it mostly produces 3 a.m. outages — rotate those with your secrets
manager instead.

### Password strength: the validate_password component

In 8.4 password validation is a **component**, installed with
`INSTALL COMPONENT`, not the old plugin
([Password Validation Component Installation](https://dev.mysql.com/doc/refman/8.4/en/validate-password-installation.html)):

```sql test
INSTALL COMPONENT 'file://component_validate_password';
SHOW GLOBAL VARIABLES LIKE 'validate_password.%';
SELECT VALIDATE_PASSWORD_STRENGTH('password123')      AS weak,
       VALIDATE_PASSWORD_STRENGTH('Lesson-pass-2026') AS strong;
```

```text
+-------------------------------------------------+--------+
| Variable_name                                   | Value  |
+-------------------------------------------------+--------+
| validate_password.changed_characters_percentage | 0      |
| validate_password.check_user_name               | ON     |
| validate_password.dictionary_file               |        |
| validate_password.length                        | 8      |
| validate_password.mixed_case_count              | 1      |
| validate_password.number_count                  | 1      |
| validate_password.policy                        | MEDIUM |
| validate_password.special_char_count            | 1      |
+-------------------------------------------------+--------+
+------+--------+
| weak | strong |
+------+--------+
|   50 |    100 |
+------+--------+
```

```sql test expect-error
CREATE USER 'lesson_weak'@'%' IDENTIFIED BY 'password123';
```

```text
ERROR 1819 (HY000) at line 1: Your password does not satisfy the current policy requirements
```

In this lab, the component did **not** reach the replica: `INSTALL
COMPONENT` left the primary's GTID set unchanged and the replica's
`mysql.component` table empty. Install it on every server, or a failover
silently drops your password policy.

```bash test
./lab sql replica -N -e "SELECT COUNT(*) AS components_on_replica FROM mysql.component"
./lab sql -e "UNINSTALL COMPONENT 'file://component_validate_password'"
```

```text
0
```

## Common mistakes and troubleshooting

- **`SET GLOBAL x = DEFAULT` to "undo" a change.** `DEFAULT` is the
  compiled-in default, not your option file's value. `long_query_time`
  becomes 10, not the 1 in `dbre.cnf`. Set the configured value explicitly.
- **Editing `my.cnf` and expecting a change.** Option files are read at
  startup. Edit the file *and* `SET GLOBAL` (if dynamic), or plan a restart.
- **Forgetting `mysqld-auto.cnf`.** A `SET PERSIST` made months ago
  overrides your carefully reviewed option file at every restart. Check
  `performance_schema.persisted_variables`.
- **`RESET PERSIST` and done.** It only edits the file; the running value
  stays until you change it or restart.
- **Granting a role and forgetting the default.** The account logs in with
  nothing. `SET DEFAULT ROLE` (or `activate_all_roles_on_login`).
- **Accounts with host names under `skip_name_resolve`.** They never match.
  Use IP addresses or subnet patterns.
- **"Access denied" for an account with `REQUIRE SSL`** connecting over the
  socket or with `--ssl-mode=DISABLED`. That is the requirement working.
- **Turning `mysql_native_password` back on** for an old driver and leaving
  it on. Upgrade the driver.
- **Ancient replication syntax in scripts.** `SHOW SLAVE STATUS` and
  friends are syntax errors in 8.4.

## Further reading

- [Using Option Files](https://dev.mysql.com/doc/refman/8.4/en/option-files.html)
- [Using System Variables](https://dev.mysql.com/doc/refman/8.4/en/using-system-variables.html)
- [Persisted System Variables](https://dev.mysql.com/doc/refman/8.4/en/persisted-system-variables.html)
- [Privileges Provided by MySQL](https://dev.mysql.com/doc/refman/8.4/en/privileges-provided.html)
- [Using Roles](https://dev.mysql.com/doc/refman/8.4/en/roles.html)
- [Using Encrypted Connections](https://dev.mysql.com/doc/refman/8.4/en/using-encrypted-connections.html)
- [General Security Guidelines](https://dev.mysql.com/doc/refman/8.4/en/security-guidelines.html)

## Next

Do the [exercises](exercise.md): find and undo configuration drift, then
lock down an over-privileged reporting account. Then take the
[quiz](quiz.md).
