# Quiz — Installation, configuration and secure access

Answer each question before opening the answer.

**1.** Your team runs MySQL 8.0 and wants "the newest stable version". A
colleague suggests 9.x because the number is bigger. What do you recommend
for a production OLTP database, and why?

<details>
<summary>Answer</summary>

The LTS series, 8.4. It receives only necessary fixes, with no removals
within the series, and follows Oracle's Lifetime Support Policy (5 years
premier, 3 years extended). Innovation releases (9.x) change behaviour and
remove features from one release to the next; they suit teams that can
upgrade often.

</details>

**2.** After upgrading to 8.4, a monitoring script fails with a syntax error
on `SHOW SLAVE STATUS`. Why, and what is the fix?

<details>
<summary>Answer</summary>

The `MASTER`/`SLAVE` statement forms were removed in 8.4.0. Use
`SHOW REPLICA STATUS` (and `START REPLICA`, `CHANGE REPLICATION SOURCE TO`,
`SHOW BINARY LOG STATUS`, ...).

</details>

**3.** A container's `MYSQL_ROOT_PASSWORD` was changed in the deployment
manifest and the container restarted. The old root password still works.
Why?

<details>
<summary>Answer</summary>

The entrypoint only initialises (and sets the root password) when the data
directory is empty. On an existing volume it starts the server directly, so
the variable is ignored. Change the password with `ALTER USER`.

</details>

**4.** `max_connections = 500` is in `/etc/mysql/conf.d/app.cnf`, but
`SELECT @@max_connections` returns 1000 after a restart. List the places
you would check, in the order the server applies them.

<details>
<summary>Answer</summary>

Option files in the order `mysqld --verbose --help` prints (including files
pulled in by `!include`/`!includedir`; the last instance of an option wins),
then the command line (systemd unit, container arguments), then
`mysqld-auto.cnf` in the data directory. `performance_schema.variables_info`
answers it in one query: `VARIABLE_SOURCE` and `VARIABLE_PATH` for
`max_connections`.

</details>

**5.** You run `SET GLOBAL long_query_time = 0.5`, then run a slow query in
the same session. It is not in the slow log. Why?

<details>
<summary>Answer</summary>

`SET GLOBAL` changes the global value, which only new sessions copy. Your
session kept its `@@SESSION.long_query_time`. Reconnect, or also run
`SET SESSION long_query_time = 0.5`.

</details>

**6.** Fill in: which statement changes the running value but not the next
restart; which changes the next restart but not the running value; which
does both?

<details>
<summary>Answer</summary>

`SET GLOBAL` — running only. `SET PERSIST_ONLY` (or editing an option
file) — next restart only. `SET PERSIST` — both. `RESET PERSIST` removes
the persisted setting and does not touch the running value.

</details>

**7.** An application should connect from `10.20.0.0/16` and only read and
write the `orders` schema. Write the account and grant statements, using a
role.

<details>
<summary>Answer</summary>

```sql
CREATE ROLE 'orders_rw';
GRANT SELECT, INSERT, UPDATE, DELETE ON orders.* TO 'orders_rw';
CREATE USER 'orders_app'@'10.20.0.0/255.255.0.0'
  IDENTIFIED BY '<from your secrets manager>' REQUIRE SSL;
GRANT 'orders_rw' TO 'orders_app'@'10.20.0.0/255.255.0.0';
SET DEFAULT ROLE 'orders_rw' TO 'orders_app'@'10.20.0.0/255.255.0.0';
```

`'10.20.%'` would also match, but wildcards in host values are deprecated.
Without `SET DEFAULT ROLE`, the role is inactive at login.

</details>

**8.** Give three concrete reasons, beyond "it is bad practice", why an
application must not connect as root.

<details>
<summary>Answer</summary>

Any three of: `read_only` does not stop it (only `super_read_only` does),
so a misrouted application can write to a replica; it can use the
connection reserved above `max_connections` for administrators, locking the
DBA out when connections run out; `init_connect` is skipped for it; any SQL
injection becomes full control of every schema, the accounts and the server
settings; its actions cannot be told apart from the DBA's in logs and audit.

</details>

**9.** `CREATE USER ... IDENTIFIED WITH mysql_native_password` fails on 8.4
with "Plugin 'mysql_native_password' is not loaded". The vendor of an old
reporting tool asks you to enable it. What do you weigh up?

<details>
<summary>Answer</summary>

It is deprecated and disabled by default in 8.4; enabling it
(`mysql_native_password=ON`, a restart) weakens authentication for that
account and keeps a dependency on a mechanism that later releases remove.
Prefer upgrading the tool's client library to one that supports
`caching_sha2_password`. If you must enable it, limit it to that one account
and put a removal date on it.

</details>

**10.** What is the difference between `REQUIRE SSL` on an account and
`require_secure_transport = ON`? Which one stops a local socket connection?

<details>
<summary>Answer</summary>

`REQUIRE SSL` applies to one account: it can only log in over TLS, so a
socket connection is refused. `require_secure_transport = ON` applies to
every account: TCP connections without TLS are refused, but socket
connections count as secure and are allowed.

</details>

**11.** You installed `validate_password` on the primary of a two-server
replication setup. A month later, after a failover, a user sets the password
`password1`. How was that possible?

<details>
<summary>Answer</summary>

`INSTALL COMPONENT` is not replicated: in the lab, the primary's GTID set
did not change and the replica's `mysql.component` stayed empty. The new
primary never had the component. Install components on every server, and
check `mysql.component` as part of failover readiness.

</details>
