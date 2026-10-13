# Founder review checklist

For Andres Kepler, before this course is announced as MoiToi.TECH's. The
material was drafted with AI assistance and verified mechanically: every
lesson command and every exercise runs in CI, and every cited manual page
exists. What a machine cannot verify is whether it reads like the work of
someone who has run these systems in production. That is this review.

Tick each box in the pull request, or note what must change.

## 1. Decisions to confirm

- [ ] **Licences.** Apache 2.0 for code (`labs/`, `.github/`), CC BY 4.0 for
      content (`courses/`, `docs/`). CC BY allows commercial reuse with
      attribution, including by competing trainers. The alternative,
      CC BY-SA, would force derivatives to stay open.
- [ ] **Course length.** The brief asked for 8–12 hours; the modules estimate
      about 12 hours plus 2–3 for the final challenge. Accept, or name
      modules to trim.
- [ ] **Course directory name** `courses/mysql-production-dba/` (the brief's
      sketch used `mysql-fundamentals/`). Renaming later breaks links.
- [ ] **Contact addresses.** `connect@moitoi.tech` is named for security
      reports and code-of-conduct reports.
- [ ] **No certification alignment** (research.md §4.5), and the roadmap's
      "Not planned" list: no LMS, no paid tier of this repository.
- [ ] **MySQL version.** Pinned to MySQL 8.4.11, the newest 8.4 LTS
      release. Docker's `lts` tag now points to MySQL 9.7 (checked
      13 Oct 2026), so 8.4 is the previous LTS series, not the newest.
      Dependabot proposes 8.4.x patch updates monthly and ignores newer
      series; CI re-runs the full lab on each. Moving to 9.7 is a course
      revision, not a dependency bump.

## 2. First-hand experience to add

The lessons never invent experience. Where a real story would make a point
land, they carry an HTML comment, invisible on GitHub, listing what is
missing. Each needs one of: a short sanitised story in your voice, or the
comment deleted. Find them all with:

```bash
grep -rn "founder-review" courses/
```

| Module | Section | What would help |
|---|---|---|
| 1 | The two logs | Relaxed durability (`innodb_flush_log_at_trx_commit=2`, `sync_binlog=0`) and what was lost in a host crash |
| 2 | SET GLOBAL / SET PERSIST | Configuration drift that bit after a restart or failover |
| 3 | Purge and history list | A forgotten transaction driving the history list into the millions |
| 3 | Finding the blocker | A root blocker that was an idle console session or a stuck job |
| 5 | Workload-first method | Tuning configuration while the real cause was one statement |
| 6 | RPO and RTO | Agreeing (or never agreeing) RPO/RTO with a client |
| 6 | Snapshots | A snapshot-based restore: consistency or restore time |
| 6 | Restore testing | How MoiToi.TECH schedules and alerts on restore tests |
| 6 (exercise) | Restore routes | Which route MoiToi.TECH picks in practice |
| 7 | Errant transactions | A failover that went wrong because of errant GTIDs |
| 7 | Split brain | A split-brain or fencing decision |
| 8 | Alert design | An alert that never fired, or fired so often it was ignored |
| 9 | Communication | An incident update that helped, or one that guessed and hurt |
| 9 | Killing sessions | A killed batch job whose rollback outlasted the original run |
| 9 | Disk full | Which file grew and how it was found |
| 10 | The brief | What a real multi-fault incident felt like |
| 10 (rubric) | Strong review | An excerpt from a real, sanitised post-incident review |

Never paste employer or client details, hostnames, schemas or data. The
contribution rules forbid it for everyone, including us.

## 3. Technical spot checks

Read these passages as a senior reviewer. They are the places where the
course states something learned from the lab rather than from the manual,
or simplifies deliberately.

- [ ] **Module 2**: `INSTALL COMPONENT` is not replicated (observed: GTID set
      unchanged, replica's `mysql.component` empty); a login refused for
      lack of TLS did not count towards `FAILED_LOGIN_ATTEMPTS` (observed).
- [ ] **Module 3**: history list length does not drop on an idle server
      until purge frees rollback segments (observed; the lesson teaches
      watching the trend). Statement that online DDL takes an exclusive
      metadata lock briefly at start and end.
- [ ] **Module 4**: adding or dropping an index resets that table's
      Performance Schema index-usage counters (observed); foreign-key checks
      do not count as index reads in `sys.schema_unused_indexes` (observed).
- [ ] **Module 5**: the 8.4 `mysql` client's `select $$` probe counted as a
      1064 error (observed, undocumented); `mysqldumpslow` dies when `-t`
      exceeds the number of distinct statements (observed).
- [ ] **Module 6**: the PITR exercise restores *in place* on the primary
      with the replica attached and replays with
      `--exclude-gtids … --skip-gtids`. After the PR #1 review it teaches
      restore to a separate instance as the preferred route on a live
      system, and in place as an explicitly offline lab technique: the lab's
      workload is stated to be stopped (and checked in the processlist),
      writers are fenced and drained before `FLUSH BINARY LOGS` marks the
      replay boundary, the window's binlogs are kept as evidence, and
      writes come back only after verification. `super_read_only` is named
      as the wrong fence (it blocks the restore too). Confirm this stance.
- [ ] **Module 7**: `sql_replica_skip_counter` does not error under GTIDs in
      8.4.11 — the `SET` succeeds with warning 4016 and nothing is skipped
      (observed; the manual says it cannot be issued).
- [ ] **Module 8**: with the applier stopped, `Seconds_Behind_Source` is NULL
      and the exporter drops the series, so a lag-only alert stays silent
      (observed, unit-tested with promtool).
- [ ] **Module 9**: one extra connection is reserved for `CONNECTION_ADMIN`
      (observed in 8.4.11); `admin_address` cannot be persisted (error 1238,
      observed). Quiz Q12's Kubernetes `terminationGracePeriodSeconds`
      analogy is general knowledge, not checked against Kubernetes docs.
- [ ] **Module 10**: the 148 locked rows are now traced (observed in
      `performance_schema.data_locks` with the scenario running, 8.4.11):
      `EXPLAIN` shows a `range` scan on `PRIMARY` (`key_len` 16, both key
      parts) from `(1,'TLL')` to `(50,'TLL')`; it holds one record-only lock
      on `(1,'TLL')` and next-key locks on all three warehouses of products
      2–50, 1 + 49 × 3 = 148, nothing beyond the range. The walkthrough
      shows the breakdown query (doctested).
- [ ] **Deferred topics** (Group Replication, InnoDB Cluster, Orchestrator,
      ProxySQL, XtraBackup internals) are described from documentation only,
      not run in the lab.

## 4. Brand and voice

- [ ] The README uses the official wordmark files from
      `moitoi.tech/brand/` (primary, and reverse in dark mode) and no
      invented logo. Check it renders acceptably on GitHub in both themes.
- [ ] Name usage: MoiToi.TECH on first mention; no "MoiToi Tech".
- [ ] Voice: concise, mechanism-first, no filler. Flag any paragraph that
      sounds generic.

## 5. Before announcing

- [ ] Read module 1 and module 10 end to end as a student, on a clean clone,
      following only the README.
- [ ] Do one exercise without hints and note anything unclear.
- [ ] Both CI workflows green on `main`.
- [ ] Decide where the course is announced (moitoi.tech, LinkedIn) — not
      part of this change.

## Known limitations (documented to students)

- Lab sized for a laptop: shows mechanisms, not production-scale numbers.
- One primary, one async replica; no Group Replication or automated
  failover.
- Windows is supported through WSL 2 only, and not tested in CI.
- First `./lab up` needs network access to Docker Hub and repo.mysql.com.
- A disk-full incident is discussed, not simulated (it cannot be made safe
  and deterministic on a shared Docker disk).
- Timings in output samples come from one machine and will differ.
