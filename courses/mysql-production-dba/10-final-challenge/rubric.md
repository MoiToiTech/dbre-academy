# Module 10 — Self-assessment rubric

`./lab check 10-final-incident` tells you whether the system ended up in a
good state. It cannot tell you whether you got there well: in the right order,
without gambling, with the evidence written down, and with a review that would
stop it happening again. That is what this rubric is for. It replaces the
quiz.

Score yourself honestly from your incident log and your review, not from
memory. For each row, pick the column that matches what you *did*. If you can,
swap reviews with someone else on the course and score each other's — a
review is written for readers who were not there.

## Part A — Handling the incident

| Area | Needs work | Solid | Strong |
|---|---|---|---|
| Triage | Started on whatever looked interesting | Ranked the three by impact | Ranked them, said why, and declared a severity in the log |
| First look | Jumped to one hypothesis | Ran a broad check first | Broad check, then confirmed each hypothesis with a second source |
| Mitigation | Stopped the app or restarted a server | Released the blocker with `KILL` | Identified the session's owner and work first; noted the stock correction must be redone |
| Safety | A change made something worse | No new damage | Every change recorded with time and the reason it was safe |
| Replica repair | Skipped the transaction, or left an errant GTID | Data repaired, replication running | Repaired with `sql_log_bin = 0`, then verified other rows were not missing too |
| API fix | Index on `status` alone, or none | `(status, created_at)` | Built online, checked `EXPLAIN` before and after, and the app log afterwards |
| Verification | Trusted that it worked | `./lab check` passes | Check passes and the user-facing symptoms are confirmed gone |
| Communication | No updates | Updates at start and end | Regular updates in the four-part shape: impact, known, doing, next |

Things that should cost you a column, whatever else you did:

- stopping `<project>-shop-app` or restarting a database to make an error go
  away;
- `RESET REPLICA ALL`, rebuilding the replica, or `--skip-grant-tables`;
- skipping the failed replication transaction without repairing the data;
- opening `solve.sh` before you were done (note it if you did — that is
  honest, and fine for a first attempt).

## Part B — The post-incident review

A strong review, written from
[the template](../../../docs/templates/postmortem.md), has all of these:

- [ ] **A summary a manager can read on a phone.** What broke, for whom, for
      how long, what fixed it, the one thing that most needs to change.
- [ ] **Impact in numbers, with sources.** Failed checkouts from the
      application log, how long the reports were wrong and which payment was
      affected, API latency before and after. Unknowns stated as unknown.
- [ ] **A timeline in UTC from your log**, including detection, each decision,
      each change and when impact ended — not reconstructed from memory.
- [ ] **Mechanisms named precisely.** "An idle session held row locks on
      `shop.inventory` for N minutes; checkout waited 20 s
      (`innodb_lock_wait_timeout`) and failed with 1205", not "the database
      was locked".
- [ ] **Contributing factors, not a single root cause.** Three faults, three
      kinds: a person's interactive session, a script run against the wrong
      host with privileges that let it bypass `super_read_only`, a query
      shipped without an index review. And the detection gaps: no alert on
      idle-in-transaction sessions, a replication-stopped alert that did not
      page, a slow-log threshold blind to cheap-but-frequent queries.
- [ ] **Blameless language.** Describes what people did and why it made sense
      at the time ("the correction was started before a meeting ran over"),
      never who was careless. The warehouse colleague and the data team are
      part of the system, not its fault.
- [ ] **Action items that change the system**, each with one owner, a
      priority and a tracking link. At least one each for prevent, detect and
      mitigate. "Be more careful" is not an action item; "the back-office tool
      commits each correction itself and no longer exposes raw SQL" is.
- [ ] **Where you were lucky.** For example: the bad row was a single payment;
      the replica's I/O thread kept receiving the binary log, so nothing had to
      be re-fetched; the refund was on the primary, so no money was wrong —
      only the report.
- [ ] **Open questions.** Did the clean-up script delete only one row? Has the
      stock correction been redone? Who checks?

Scoring: 8–9 boxes is a review you could publish inside a company; 5–7 needs
another pass; fewer than 5, rewrite it from your incident log before moving
on.

## Common weaknesses

- The timeline starts when you opened a terminal, not when users were first
  affected (the scenario's alerts give you the times).
- Action items without owners, or all owned by "the DB team".
- The replica repair described as "fixed replication" — without saying how
  you know the data is now correct.
- The three faults merged into one story with one cause because they arrived
  together. Coincidence in time is not causation; say so explicitly when
  you decide they are unrelated.

## Where to go next

If Part A had several "Needs work" rows, repeat the challenge in a few days
without the walkthrough — the setup is deterministic, so you can compare your
two logs. If Part B was weak, read the annotated example in the SRE workbook's
[Postmortem Culture](https://sre.google/workbook/postmortem-culture/) chapter
and rewrite yours.

<!-- founder-review: an excerpt from a real (sanitised) review the author
wrote or reviewed would show what "strong" looks like better than a
checklist -->
