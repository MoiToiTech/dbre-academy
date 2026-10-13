# Module 9 — Exercise: two outages

`time: ~45 min` · `scenarios: 09-too-many-connections, 09-wont-start`

Two incidents, one after the other. Treat each as real: note the time you
start, write down what you observe and every change you make, and stop the
impact before you go looking for the full story. Your notes are the raw
material for a post-incident review
([template](../../../docs/templates/postmortem.md)).

Run everything from `labs/`. Each scenario has a reference fix in
`labs/scenarios/<name>/solve.sh`; try without it first. The walkthroughs at
the end of each exercise are collapsed — open them when you are done or stuck.

## Exercise 1 — "Too many connections"

**09:41 UTC.** Checkout is failing. The application log is full of:

```text
ERROR 1040 (08004): Too many connections
```

Ten minutes ago the team deployed a new version of the invoice worker. Nobody
has touched the database configuration since the start of the month — as far
as anyone knows.

Start the incident:

```bash test
./lab scenario setup 09-too-many-connections
```

The check fails while the fault is present:

```bash test expect-error
./lab check 09-too-many-connections
```

Your tasks:

1. **Get in.** Open one root session (`./lab sql`). Think about why it works
   when the application cannot, and keep it to one session.
2. **Find the source.** Who holds the connections, from which client address,
   doing what? Which container is that address? (`docker network inspect`
   lists the lab network's members.)
3. **Mitigate.** Stop the source. Try `KILL` on a few of the connections
   first and watch what happens over the next 30 seconds — then decide what
   actually stops them. Treat the invoice worker as a deployment you are
   allowed to roll back; the `app` account is shared with checkout, so do not
   lock it.
4. **Find the second fault.** The limit is lower than the configuration file
   says. Where did that value come from, when, and who set it? Make sure it
   does not come back at the next restart.
5. **Verify.** `./lab check 09-too-many-connections` passes.

Then answer for your notes: what would have detected this before checkout
failed? What stops one service exhausting the whole server next time?

<details>
<summary>Walkthrough</summary>

**Get in and look.** Root has `CONNECTION_ADMIN`, so it gets the one
connection mysqld keeps in reserve. Group the sessions:

```sql test
SELECT USER, SUBSTRING_INDEX(HOST, ':', 1) AS client, COMMAND,
       COUNT(*) AS conns, MIN(TIME) AS min_idle_s, MAX(TIME) AS max_idle_s
FROM performance_schema.processlist
GROUP BY USER, client, COMMAND
ORDER BY conns DESC;
```

```text
+-----------------+---------------+------------------+-------+------------+------------+
| USER            | client        | COMMAND          | conns | min_idle_s | max_idle_s |
+-----------------+---------------+------------------+-------+------------+------------+
| app             | 192.168.156.4 | Sleep            |    29 |          2 |          4 |
| event_scheduler | localhost     | Daemon           |     1 |         59 |         59 |
| repl            | 192.168.156.2 | Binlog Dump GTID |     1 |         56 |         56 |
| root            | localhost     | Query            |     1 |          0 |          0 |
+-----------------+---------------+------------------+-------+------------+------------+
```

29 idle `app` sessions from one address, plus the replica's dump thread: 30,
the whole limit. Idle times stay low because the client pings every few
seconds — a connection pool keeping its connections alive.

**Which client is that?** With `skip_name_resolve` the server only knows the
IP address. Map it on the Docker network (your addresses will differ):

```bash test
docker network inspect "${DBRE_PROJECT:-dbre}_default" \
  --format '{{range .Containers}}{{.IPv4Address}}  {{.Name}}{{"\n"}}{{end}}'
```

```text
192.168.156.3/24  dbre-primary-1
192.168.156.4/24  dbre-invoice-worker
192.168.156.2/24  dbre-replica-1
```

**Why KILL is not enough.** Killing the sessions frees the slots for a few
seconds; the worker reconnects and takes them back, because nothing limits its
pool. Kill them one statement list at a time — `./lab sql ... | ./lab sql`
would need two root sessions at once, and there is only one reserved slot:

```bash test
kills="$(./lab sql -N -e "SELECT CONCAT('KILL ', ID, ';')
                          FROM performance_schema.processlist WHERE USER = 'app'")"
./lab sql -e "$kills"
sleep 20
./lab sql -N -e "SELECT COUNT(*) AS app_sessions_20s_later
                 FROM performance_schema.processlist WHERE USER = 'app'"
```

```text
29
```

**Mitigate: stop the source.** Roll back the worker — here, stop its
container. Its connections close with it.

```bash test
docker stop "${DBRE_PROJECT:-dbre}-invoice-worker"
```

**The second fault: a persisted limit.** `mysql/primary.cnf` says 200; the
server says 30. `variables_info` tells you where a value came from and
`persisted_variables` whether it will survive a restart:

```sql test
SELECT i.VARIABLE_NAME, i.VARIABLE_SOURCE, p.VARIABLE_VALUE AS persisted,
       i.SET_TIME, i.SET_USER
FROM performance_schema.variables_info i
JOIN performance_schema.persisted_variables p USING (VARIABLE_NAME)
WHERE i.VARIABLE_NAME = 'max_connections';
```

```text
+-----------------+-----------------+-----------+----------------------------+----------+
| VARIABLE_NAME   | VARIABLE_SOURCE | persisted | SET_TIME                   | SET_USER |
+-----------------+-----------------+-----------+----------------------------+----------+
| max_connections | DYNAMIC         | 30        | 2026-10-13 11:05:57.246505 | root     |
+-----------------+-----------------+-----------+----------------------------+----------+
```

That `SET_TIME` goes in your timeline: the limit was lowered minutes before
the deploy, which is why "nobody touched the configuration" felt true. Remove
the persisted value and return to the configured one:

```sql test
RESET PERSIST max_connections;
SET GLOBAL max_connections = 200;
```

```bash test
./lab check 09-too-many-connections
```

```text
Checking 09-too-many-connections
  PASS max_connections is 200 (at least 150)
  PASS no low max_connections will come back at the next restart (persisted: none)
  PASS the source of the idle connections no longer holds any
  PASS the application account can connect
All checks passed.
```

**Prevention, for the review:** give each service its own account with
`MAX_USER_CONNECTIONS` so that one pool cannot starve the others; cap the
pool size in the application; alert on `Threads_connected /
max_connections` and on `Connection_errors_max_connections`; enable the
administrative interface so that getting in never depends on one spare slot;
and review `performance_schema.persisted_variables` as part of change control.

</details>

Restore the baseline before the next exercise (safe whether or not you
solved it):

```bash test
./lab scenario reset 09-too-many-connections
```

## Exercise 2 — mysqld will not start

**02:10 UTC, planned maintenance.** The primary is restarted for a routine
change. It does not come back. The replica's reports are fine for now; the
application is down.

```bash test
./lab scenario setup 09-wont-start
```

`./lab` refuses scenario commands while the primary is down, so the check
fails with *the lab is not running* until you have it back:

```bash test expect-error
./lab check 09-wont-start
```

Your tasks:

1. **Read why it stopped.** `./lab logs primary` (Ctrl-C to stop following).
   Find the last `[ERROR]` lines before `Aborting`, and look the setting up in
   the manual.
2. **Find where the setting comes from.** It is not in `mysql/primary.cnf`.
   The data directory is in the Docker volume `<project>_primary-data`
   (`dbre_primary-data` for the default lab).
3. **Remove only the bad setting.** Another persisted setting in the same
   place is legitimate and must survive. The image has no text editor; use
   MySQL's own tools.
4. **Bring the primary back** and make sure the replica is replicating again.
5. **Verify.** `./lab check 09-wont-start` passes.

If you get stuck and want to start over, `./lab scenario reset 09-wont-start`
works with the primary down.

<details>
<summary>Walkthrough</summary>

**Read the error log.** mysqld logged why it gave up:

```bash test
docker compose logs --no-log-prefix --tail 300 primary | grep -E '\[ERROR\]'
```

```text
2026-10-13T10:37:33.681855Z 1 [ERROR] [MY-011087] [Server] Different lower_case_table_names settings for server ('1') and data dictionary ('0').
2026-10-13T10:37:33.681936Z 0 [ERROR] [MY-010020] [Server] Data Dictionary initialization failed.
2026-10-13T10:37:33.681953Z 0 [ERROR] [MY-010119] [Server] Aborting
```

`lower_case_table_names` can only be chosen when the data directory is
initialised; this one was initialised with 0. Something now asks for 1.

**Find it.** It is not in the option file, so look at the persisted settings
in the data directory, read-only, from a throwaway container on the volume:

```bash test
docker run --rm -v "${DBRE_PROJECT:-dbre}_primary-data:/var/lib/mysql:ro" \
  --entrypoint cat dbre-academy/mysql:8.4 /var/lib/mysql/mysqld-auto.cnf
echo
```

```text
{"Version": 2, "mysql_static_variables": {"lower_case_table_names": {"Value": "1",
"Metadata": {"Host": "localhost", "User": "root", "Timestamp": 1791887841829122}}},
"mysql_dynamic_variables": {"log_slow_extra": {"Value": "ON", "Metadata": {...}}}}
```

Someone ran `SET PERSIST_ONLY lower_case_table_names = 1`, which only takes
effect at the next start. `log_slow_extra` is a legitimate setting that must
stay — deleting the file would lose it.

**Rescue instance.** Start mysqld on the same volume, with the same option
file, ignoring `mysqld-auto.cnf` (`--persisted-globals-load=OFF`), and with
**no network**, so that neither the application nor the replica can reach a
half-repaired server:

```bash test
docker run -d --name "${DBRE_PROJECT:-dbre}-rescue" --network none \
  -v "${DBRE_PROJECT:-dbre}_primary-data:/var/lib/mysql" \
  -v "$PWD/mysql/primary.cnf:/etc/mysql/conf.d/dbre.cnf:ro" \
  dbre-academy/mysql:8.4 mysqld --persisted-globals-load=OFF
until docker exec "${DBRE_PROJECT:-dbre}-rescue" \
      mysqladmin -uroot -pdbre-lab-root ping --silent 2>/dev/null; do sleep 2; done
```

Connect through the socket inside the container (interactively:
`docker exec -it <project>-rescue mysql -uroot -p`). The persisted settings
are still readable and `RESET PERSIST` still edits the file — it just was not
applied at start-up:

```bash test
docker exec -e MYSQL_PWD=dbre-lab-root "${DBRE_PROJECT:-dbre}-rescue" \
  mysql -uroot --table -e "
    SELECT @@persisted_globals_load, @@lower_case_table_names;
    SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.persisted_variables;
    RESET PERSIST lower_case_table_names;
    SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.persisted_variables;"
```

```text
+--------------------------+--------------------------+
| @@persisted_globals_load | @@lower_case_table_names |
+--------------------------+--------------------------+
|                        0 |                        0 |
+--------------------------+--------------------------+
+------------------------+----------------+
| VARIABLE_NAME          | VARIABLE_VALUE |
+------------------------+----------------+
| log_slow_extra         | ON             |
| lower_case_table_names | 1              |
+------------------------+----------------+
+----------------+----------------+
| VARIABLE_NAME  | VARIABLE_VALUE |
+----------------+----------------+
| log_slow_extra | ON             |
+----------------+----------------+
```

Shut the rescue instance down cleanly and remove it — two mysqld processes
must never share a data directory. `docker exec` may report an error as the
container exits underneath it; `docker wait` prints mysqld's exit code (0):

```bash test
docker exec -e MYSQL_PWD=dbre-lab-root "${DBRE_PROJECT:-dbre}-rescue" \
  mysqladmin -uroot shutdown || true
docker wait "${DBRE_PROJECT:-dbre}-rescue"
docker rm "${DBRE_PROJECT:-dbre}-rescue"
```

**Bring the primary back, then the replica.** If the outage lasted longer
than 10 retries × 5 seconds, the replica's I/O thread has given up
(`Last_IO_Error: ... This was attempt 10/10 ...`). `START REPLICA` is safe
either way: on a running replica it only adds a note.

```bash test
docker compose start primary
until [ "$(docker inspect -f '{{.State.Health.Status}}' \
           "$(docker compose ps -q primary)")" = healthy ]; do sleep 2; done
./lab sql replica -e "START REPLICA"
./lab check 09-wont-start
```

```text
Checking 09-wont-start
  PASS the primary is up and accepts connections
  PASS lower_case_table_names is no longer persisted in mysqld-auto.cnf
  PASS the legitimate persisted setting log_slow_extra is still persisted
  PASS the primary kept its data (shop.orders rows)
  PASS replication threads on the replica (IO/SQL)
  PASS the replica has caught up with the primary
All checks passed.
```

**For the review:** the trigger was the restart; the cause was a setting
persisted earlier that could never work on this data directory. Useful action
items: review `performance_schema.persisted_variables` before every planned
restart; test configuration changes on a replica first; keep `SET PERSIST`
changes in change control like option-file changes.

</details>

Restore the baseline:

```bash test
./lab scenario reset 09-wont-start
```
