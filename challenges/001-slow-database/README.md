<p>
  <a href="https://moitoi.tech/academy">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://moitoi.tech/brand/moitoi-tech-reverse.svg">
      <img src="https://moitoi.tech/brand/moitoi-tech-primary.svg" alt="MoiToi.TECH" width="200">
    </picture>
  </a>
</p>

# Challenge #001: The database is slow. Nobody changed anything

## Your production database is slow. Can you figure out why?

`MySQL 8.4` · `intermediate` · `20–40 minutes` · `free` · `runs on your laptop`

A production incident you solve on your own machine. A real MySQL server, a
real workload, a real slowdown — nothing is scripted to look broken. You find
the cause, fix it safely, and a check tells you whether the fix holds.

Part of [MoiToi Engineering Academy](https://moitoi.tech/academy) —
*Learn. Break. Fix. Repeat.*

## The briefing

> **09:12, Tuesday.** Customers say their order confirmation e-mails arrive
> late. The order service's outbox workers — the ones that send those e-mails —
> have been getting slower since the night. The application team checked: no
> deploy, no config change, no schema change since last week. The database
> host's CPU is mostly idle, the disk is fine, memory is fine.
>
> You are the engineer on call for the database. Find out why it is slow, fix
> it without losing data, and make sure it stays fixed.

## Start

You need Docker with Compose v2 (Docker Desktop, OrbStack, Colima or Docker
Engine), about **1.5 GiB of memory for Docker** and **2 GB of disk**. amd64
and arm64 (Apple silicon) both work; on Windows, use WSL 2. No account, no
cloud, nothing leaves your machine.

```bash
git clone https://github.com/MoiToiTech/dbre-academy.git
cd dbre-academy/challenges/001-slow-database
./challenge doctor    # checks Docker, memory and the port
./challenge start     # first run pulls MySQL 8.4 (~600 MB); then under a minute
```

When it prints **The incident is live**, start the clock.

| Command | What it does |
|---|---|
| `./challenge status` | The on-call dashboard: latency, throughput, outbox backlog, server load |
| `./challenge sql` | A MySQL shell as `root` |
| `./challenge logs` | The order service's log |
| `./challenge verify` | Is the incident resolved? Exit code 0 means yes |
| `./challenge reset` | Back to the start of the incident (about 30 seconds) |
| `./challenge clean` | Remove the containers and data |

`make start`, `make verify`, `make reset` and `make clean` do the same.
MySQL listens on `127.0.0.1:13306` (user `root`, password `challenge`) if
you prefer your own client; set `CH001_PORT` to use another port.

## The rules

- **You own the database, not the application.** Don't change the order
  service or its queries — you can't redeploy it in the middle of an incident.
- **Don't lose data.** Orders and the outbox history must survive your fix.
  `verify` checks.
- **The fix has to hold.** A graph that dips for a minute is not a fix.
  `verify` checks that too.
- Everything else is allowed. Read `docker-compose.yml` if you like — but the
  incident is in the database, and that is where the evidence is.

## Where to look

These are the tools an on-call DBA reaches for. They do not point at the
answer; the evidence does.

```sql
SHOW FULL PROCESSLIST;
SELECT * FROM sys.statement_analysis LIMIT 10;
EXPLAIN SELECT ...;            -- and EXPLAIN ANALYZE
SHOW ENGINE INNODB STATUS\G
SELECT * FROM performance_schema.data_locks LIMIT 10;
SELECT * FROM information_schema.innodb_metrics WHERE status = 'enabled';
```

Write down what you expected each one to show and what it actually shows.
The gap between the two is the investigation.

## Hints

Open them one at a time, only when you are stuck.

<details>
<summary>Hint 1 — start from the symptom</summary>

Which statement got slower? Compare its latency with the number of rows it
examines. Is the work it reports enough to explain the time it takes?

</details>

<details>
<summary>Hint 2 — the plan is not the problem</summary>

`EXPLAIN` uses the right index. So ask a different question: what does the
slow statement *touch* besides the rows it returns? Run it yourself inside a
transaction (`START TRANSACTION; … ; ROLLBACK;`) and look at
`performance_schema.data_locks` before you roll back.

</details>

<details>
<summary>Hint 3 — where does that come from?</summary>

Updated rows do not vanish from an index at once. Something has to clean up
after them, and something can stop it. The `TRANSACTIONS` section of
`SHOW ENGINE INNODB STATUS` has a number worth watching.

</details>

<details>
<summary>Hint 4 — who is stopping it?</summary>

Look at `information_schema.innodb_trx` next to the process list. How old is
the oldest transaction, who owns it, and what is it doing right now?

</details>

<details>
<summary>Hint 5 — before you act</summary>

Before you end anything, prove it is safe: is it writing, is it holding
locks, how long would undoing it take? Then check the fix holds — not just
that the next minute looks better.

</details>

## What you will practise

- Telling a statement that does more work from one that waits longer.
- Which MySQL counters to trust when `EXPLAIN` and "rows examined" look
  healthy.
- Taking a production action safely: evidence first, then the smallest
  change that removes the cause.
- Proving a fix holds rather than watching a graph dip.

## Done?

`./challenge verify` prints your time and a line you can share. Please keep
the cause out of public posts so others can still enjoy it — say how long it
took, what misled you, or what you'd monitor now, and put anything more behind
a spoiler.

Then read the full explanation, the wrong turns and how to stop it happening
again: **[instructor/README.md](instructor/README.md)** (spoilers).

Want more? The free [MySQL Production DBA Fundamentals](https://moitoi.tech/academy#dbre)
course in this repository goes deeper, one module at a time.

## Something wrong with the lab?

[Open a lab issue](https://github.com/MoiToiTech/dbre-academy/issues/new?template=lab-problem.yml)
with the output of `./challenge doctor` and what you ran.

| | |
|---|---|
| Resources | MySQL container capped at 1 GiB; the order service and export 384 MiB together |
| Data | Synthetic and deterministic: 5,000 customers, 20,000 orders, ~400,000 outbox messages |
| Tested | From scratch on amd64 and arm64 in CI, with the incident, a symptom-only fix, the reference fix, reset and a repeat |
| Licence | Text CC BY 4.0, code Apache 2.0 — see the repository root |

---

MoiToi.TECH — We build useful technology systems. · <https://moitoi.tech/academy>
