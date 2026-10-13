# Exercises — Configuration drift and least privilege

`time: ~35 min` · `scenarios: 02-config-drift, 02-least-privilege`

Two independent exercises. Each has a setup, a task, a check and a reset.
A reference solution for each is in `labs/scenarios/<name>/solve.sh`; try
the task first.

## Exercise A — Configuration drift

`~15 min`

### The situation

Last night's on-call engineer "tuned" the primary during an incident by
typing `SET` statements into a root session, then went to bed. Nobody wrote
down what was changed. The option file `labs/mysql/primary.cnf` (in the
container: `/etc/mysql/conf.d/dbre.cnf`) is under version control and is the
source of truth.

```bash test
./lab scenario setup 02-config-drift
```

### Your task

1. Find every setting on the primary that no longer matches the option
   files — now, **and** at the next restart.
2. Put each one back to the option file's value, so that the running server
   and the next restart both match the files.
3. Do not restart the server, and do not edit the option files.

```bash test expect-error
./lab scenario check 02-config-drift
```

<details>
<summary>Hint 1 — where to look</summary>

Three places, from the lesson:

- `performance_schema.variables_info`: `VARIABLE_SOURCE = 'DYNAMIC'` means
  "changed at runtime by `SET`".
- `performance_schema.persisted_variables`: what `mysqld-auto.cnf` will apply
  at the next restart. Something can be pending there without being visible
  at runtime at all.
- `my_print_defaults mysqld` inside the container: what the option files say.

</details>

<details>
<summary>Hint 2 — what you will see</summary>

```sql
SELECT VARIABLE_NAME, VARIABLE_SOURCE, SET_TIME, SET_USER
FROM performance_schema.variables_info
WHERE VARIABLE_SOURCE = 'DYNAMIC'
ORDER BY VARIABLE_NAME;
```

```text
+--------------------------------+-----------------+----------------------------+----------+
| VARIABLE_NAME                  | VARIABLE_SOURCE | SET_TIME                   | SET_USER |
+--------------------------------+-----------------+----------------------------+----------+
| foreign_key_checks             | DYNAMIC         | 2026-10-13 10:50:59.605371 | NULL     |
| innodb_flush_log_at_trx_commit | DYNAMIC         | 2026-10-13 10:51:17.321302 | root     |
| long_query_time                | DYNAMIC         | 2026-10-13 10:51:17.321276 | root     |
| max_connections                | DYNAMIC         | 2026-10-13 10:51:17.321285 | root     |
| require_secure_transport       | DYNAMIC         | 2026-10-13 10:51:06.837484 | root     |
| sync_binlog                    | DYNAMIC         | 2026-10-13 10:51:17.327239 | root     |
+--------------------------------+-----------------+----------------------------+----------+
```

Your list may contain extra rows, like `foreign_key_checks` (set by the
dataset loader's session) or `require_secure_transport` (set to `ON` and
back to `OFF` in the lesson). `DYNAMIC` says *how* a value was last set, not
that it is wrong: compare each value with the option file before you change
anything.

</details>

<details>
<summary>Hint 3 — the traps</summary>

- `SET GLOBAL x = DEFAULT` sets the compiled-in default, which is not
  necessarily what the option file says.
- `RESET PERSIST` removes a setting from `mysqld-auto.cnf` but leaves the
  running value alone.
- A static variable persisted with `SET PERSIST_ONLY` cannot be changed at
  runtime, but it can be removed from `mysqld-auto.cnf`.

</details>

### Check

```text
$ ./lab scenario check 02-config-drift
Checking 02-config-drift
  PASS long_query_time matches the option file (1)
  PASS max_connections matches the option file (200)
  PASS innodb_flush_log_at_trx_commit matches the option file (1)
  PASS sync_binlog matches the option file (1)
  PASS skip_name_resolve is ON
  PASS no drifted settings left in mysqld-auto.cnf
All checks passed.
```

### Think about it

- Which of the five changes would have hurt most if the server had crashed
  overnight? Which would have hurt only after the next planned restart?
  (Module 1, "Two logs", has the answer for two of them.)
- `skip_name_resolve = OFF` was invisible at runtime. What would have
  changed for every new connection after the next restart?
- How would you detect this kind of drift automatically, every day, on a
  fleet of servers?

```bash test
./lab scenario reset 02-config-drift
```

## Exercise B — A least-privilege reporting account

`~20 min`

### The situation

The BI team's dashboard connects as `'report'@'%'` with password
`dbre-lab-report`. A colleague created it in a hurry:

```sql
CREATE USER 'report'@'%' IDENTIFIED BY 'dbre-lab-report';
GRANT ALL PRIVILEGES ON *.* TO 'report'@'%' WITH GRANT OPTION;
```

The dashboard only ever reads the `shop` schema. It connects over the
network.

```bash test
./lab scenario setup 02-least-privilege
```

### Your task

Make `'report'@'%'` safe, without changing its password (the dashboard's
configuration is not yours to change):

1. Create a role `reporting_ro` with `SELECT` on `shop.*` and nothing else.
2. Remove every privilege granted directly to `'report'@'%'`; it gets its
   access only through `reporting_ro`, active at login.
3. The account must only be usable over TLS.
4. Lock the account temporarily after repeated wrong passwords: between 3
   and 10 attempts, with a lock time.
5. Verify it yourself: log in as `report` over TCP, read `shop.orders`, and
   try to update it.

```bash test expect-error
./lab scenario check 02-least-privilege
```

<details>
<summary>Hint 1 — statements you will need</summary>

`CREATE ROLE`, `GRANT ... TO <role>`, `REVOKE ALL PRIVILEGES, GRANT OPTION
FROM ...`, `GRANT <role> TO <account>`, `SET DEFAULT ROLE`, and `ALTER USER`
with `REQUIRE SSL`, `FAILED_LOGIN_ATTEMPTS` and `PASSWORD_LOCK_TIME`. All
are in the lesson.

</details>

<details>
<summary>Hint 2 — testing as report</summary>

```bash
docker compose exec -T -e MYSQL_PWD=dbre-lab-report primary \
  mysql -ureport -h127.0.0.1 -e "SELECT CURRENT_USER(), CURRENT_ROLE();
                                 SELECT COUNT(*) FROM shop.orders"
```

Then try the same with `--ssl-mode=DISABLED`, and try an `UPDATE`.

`SHOW GRANTS FOR 'report'@'%'` shows the role grant; add
`USING 'reporting_ro'` to see what the role brings.

</details>

### Check

```text
$ ./lab scenario check 02-least-privilege
Checking 02-least-privilege
  PASS role reporting_ro exists
  PASS reporting_ro holds exactly SELECT on shop.*
  PASS reporting_ro has no global, table or column privileges
  PASS report@'%' has no privileges of its own (only through the role)
  PASS reporting_ro is granted to report@'%'
  PASS reporting_ro is a default role of report@'%'
  PASS report@'%' requires TLS (ssl_type ANY)
  PASS report@'%' authenticates with caching_sha2_password
  PASS failed-login tracking is on (5 attempts, lock time 1)
  PASS a connection without TLS is refused
  PASS report can read shop.orders over TLS
  PASS report cannot write to shop (ERROR 1142)
  PASS report cannot read the mysql schema
All checks passed.
```

The check logs in as `report` several times, once deliberately without
TLS. In this lab, connections refused for lack of TLS did not count as
failed logins, so the check does not lock the account.

### Think about it

- `'%'` lets `report` connect from any address. What would you change if
  the BI servers all live in `10.20.0.0/16`? What would you have to check
  first, given `skip_name_resolve`?
- The grants replicated to the replica. Should the dashboard read from the
  primary or the replica, and how does `super_read_only` on the replica
  change the risk of the old `ALL PRIVILEGES` grant?
- Before this fix, which statements could `report` have run that no audit
  of `SELECT` queries would ever notice?

```bash test
./lab scenario reset 02-least-privilege
```

Reset drops `report` and `reporting_ro`. It never touches `root`, `repl`,
`app` or `exporter`.
