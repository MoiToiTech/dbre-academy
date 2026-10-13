# Labs

A MySQL 8.4 primary and a replica in Docker, a synthetic shop dataset, and
scripted fault scenarios with automated checks. Optional Prometheus and
Grafana. Everything runs locally; nothing needs an account or a paid service.

## Requirements

| | Minimum | Notes |
|---|---|---|
| Docker | Engine 24+ with Compose v2 (`docker compose`) | Docker Desktop, OrbStack, Colima, Rancher Desktop or Linux Docker Engine |
| Memory for Docker | 2 GiB; 4 GiB with `--observability` | Each MySQL server uses a 256 MiB buffer pool |
| Disk | ~3 GiB | Images ~2 GiB, data ~0.5 GiB |
| CPU | amd64 or arm64 (Apple silicon) | Both are tested in CI |
| Shell | bash 3.2+ | macOS default bash works; on Windows use WSL 2 |
| Network | First run only | Pulls images and builds the lab image (~1 min) |

Check your machine:

```bash
./lab doctor
```

## Everyday commands

Run them from this `labs/` directory.

| Command | What it does |
|---|---|
| `./lab up` | Start primary + replica, configure replication, load data (first run) |
| `./lab up --observability` | Also start mysqld_exporter, Prometheus and Grafana |
| `./lab status` | Containers, replication health, dataset summary |
| `./lab sql` / `./lab sql replica` | MySQL shell as root on the primary / replica |
| `./lab shell` | Bash inside the primary container |
| `./lab logs primary` | Follow the MySQL error log (container log) |
| `./lab fingerprint` | Row counts and checksums of the dataset |
| `./lab scenario list` | List exercises |
| `./lab scenario setup <name>` | Inject a fault |
| `./lab check <name>` | Validate your fix |
| `./lab scenario reset <name>` | Undo the scenario |
| `./lab down` | Stop containers, keep data |
| `./lab reset` | Delete everything and start fresh (about 30 s) |
| `./lab destroy` | Delete containers and data volumes |

## What is running

| Service | Host address | Credentials (lab only) |
|---|---|---|
| primary | `127.0.0.1:13306` | `root` / `dbre-lab-root` |
| replica | `127.0.0.1:13307` | `root` / `dbre-lab-root` |
| Prometheus | <http://127.0.0.1:19090> | none |
| Grafana | <http://127.0.0.1:13000> | anonymous viewer; `admin` / `dbre-lab-grafana` |

Other accounts on the servers: `app` (data changes on `shop`), `repl`
(replication), `exporter` (monitoring). Their grants are in
[mysql/init-primary/01-users.sql](mysql/init-primary/01-users.sql).

All ports bind to `127.0.0.1` only. The passwords are public, in this
repository, and exist only to make the lab work — never reuse them, and do
not expose these ports to a network.

Port in use? Override any of them:

```bash
DBRE_PRIMARY_PORT=23306 DBRE_GRAFANA_PORT=23000 ./lab up
```

The variables are `DBRE_PRIMARY_PORT`, `DBRE_REPLICA_PORT`,
`DBRE_PROMETHEUS_PORT`, `DBRE_GRAFANA_PORT`, plus `DBRE_PROJECT` to run a
second independent lab.

## The dataset

`shop` is a small, entirely synthetic e-commerce schema: 20 000 customers,
1 000 products, 3 000 inventory rows, 200 000 orders, 500 000 order items
and 194 021 payments. Every value is computed from a row number, so every
machine gets byte-identical data and the lessons can show exact row counts
and query plans. No row comes from real customer or employer data. Schema:
[datasets/shop/01-schema.sql](datasets/shop/01-schema.sql).

A fresh lab prints this fingerprint (`./lab fingerprint`):

```text
+-------------+-----------+------------------+
| tbl         | row_count | checksum         |
+-------------+-----------+------------------+
| customers   |     20000 |   43044271163024 |
| products    |      1000 |    2172567457787 |
| inventory   |      3000 |    6454725572176 |
| orders      |    200000 |  429302637527129 |
| order_items |    500000 | 1073701965968963 |
| payments    |    194021 |  416684336679858 |
+-------------+-----------+------------------+
```

## Layout

```text
labs/
├── lab                     the CLI
├── docker-compose.yml
├── mysql/                  Dockerfile, my.cnf for each server, initial accounts
├── datasets/shop/          schema, deterministic generator, fingerprint query
├── observability/          Prometheus config and alerts, Grafana provisioning
├── scenarios/NN-name/      setup.sh, check.sh, reset.sh, solve.sh per exercise
├── scripts/lib.sh          helpers shared by ./lab and the scenarios
└── tests/                  scenario-test.sh, doctest.py, full-run.sh, static-checks.sh
```

Each scenario's `solve.sh` is the reference fix that CI uses to prove the
exercise is solvable. Try the exercise first.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `port is already allocated` | Another program uses the port. Set the matching `DBRE_*_PORT`. |
| `primary not healthy after 180s` | Usually too little memory for Docker. Check `./lab logs primary`, raise Docker's memory limit. |
| Replica shows `IO=CONNECTING` | The primary is down or restarting; `./lab status` again after it is healthy. |
| A scenario left things in a strange state | `./lab scenario reset <name>`; if that fails, `./lab reset`. |
| Image build fails on first run | It downloads packages from repo.mysql.com. Check network access and retry. |
| Apple silicon: slow start | Expected on the very first build; later starts take about 20 seconds. |

## Testing the lab

```bash
tests/static-checks.sh            # no lab needed, seconds
tests/scenario-test.sh --all      # lab running, every scenario
tests/doctest.py                  # lab running, every lesson code block
tests/full-run.sh                 # all of it from scratch, as CI does
```

The code in `labs/` and `.github/` is licensed under Apache 2.0
([LICENSE](../LICENSE)).
