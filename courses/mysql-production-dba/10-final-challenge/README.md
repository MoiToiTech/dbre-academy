# Module 10 — Final challenge: a production incident

`time: ~2–3 h` · `lab: ./lab scenario setup 10-final-incident` · `level: fundamentals`

Real incidents rarely arrive one at a time. This one has three independent
faults that surface within the same few minutes, each with its own symptom
and its own team shouting about it. You are the on-call DBRE. Triage them,
stop the impact, fix the causes without creating new ones, and write the
post-incident review. Nothing here is new — every technique is from modules 1
to 9 — but you have to choose which one, in which order, under pressure.

## How this module is organised

| File | What it is |
|---|---|
| `README.md` (this file) | The incident brief: context, alerts, reports, rules |
| [`exercise.md`](exercise.md) | How to run the challenge, hints, and a walkthrough |
| [`rubric.md`](rubric.md) | Self-assessment, in place of a quiz |

There is no quiz. A quiz checks recall; this module checks judgement, and
judgement has no single right answer to tick. `./lab check 10-final-incident`
verifies the technical end state — fault by fault — and the
[rubric](rubric.md) is how you assess the parts a script cannot: the order you
worked in, the risks you took, and the quality of your review.

## Learning objectives

- Triage several simultaneous symptoms by user impact, not by what is most
  interesting.
- Mitigate safely in a live system: no restarts, no stopping the application,
  no "fixes" that hide data problems.
- Use the evidence each layer offers: application logs, the processlist,
  InnoDB lock views, statement digests, `EXPLAIN`, replication status and the
  binary log.
- Repair a broken replica so that it is correct, not merely running.
- Write a blameless post-incident review with a timeline, contributing factors
  and owned action items.

## Prerequisites

Modules [01](../01-architecture/) to [09](../09-incident-response/), in
particular [03-innodb-transactions-locking](../03-innodb-transactions-locking/),
[04-explain-indexing](../04-explain-indexing/),
[05-performance-diagnostics](../05-performance-diagnostics/),
[07-replication-ha](../07-replication-ha/) and
[09-incident-response](../09-incident-response/). The lab must be up and
healthy (`./lab status`).

## The brief

### The company

*Lumivaal Parts* (fictional) sells marine and workshop parts online from
three warehouses (Tallinn `TLL`, Helsinki `HEL`, Riga `RIX`). The lab's `shop`
database is theirs.

| Component | In the lab | Notes |
|---|---|---|
| Shop application | container `<project>-shop-app` | Checkout and public API; account `app` |
| Back-office tool | container `<project>-backoffice-console` | Warehouse staff fix stock by hand; account `backoffice` |
| `db-primary` | service `primary` | All writes |
| `db-reports` | service `replica` | Read-only; finance and support reports read it |

`<project>` is `dbre` unless you set `DBRE_PROJECT`.

### What changed recently

- **Today 10:30 UTC** — shop release 2026.10.13: new API endpoint
  `GET /v2/orders?status=pending` for the warehouse dashboard, polled by four
  workers.
- **Today, morning** — the warehouse team in Tallinn received a delivery and
  is correcting stock levels in the back-office tool.
- **Yesterday** — a data clean-up script was run by the data team. It was
  meant for a staging copy.
- **Last week** — nothing of note in the database configuration.

### The page

```text
10:42 PAGER  [P1] shop-checkout: error rate 100% over 5 min (threshold 2%)
10:43 PAGER  [P2] api-orders: p95 latency above SLO since the 10:30 release
10:44 TICKET support: "Reports still show order 4391 as paid, refunded an hour ago"
```

### What people are saying

> **#support, 10:44** — Customer on order 4391 says we refunded them this
> morning. Our refunds report still shows the payment as captured. Is the
> refund actually done? Finance closes the day at 17:00.

> **#shop-dev, 10:45** — Checkout is throwing 500s. The logs say lock wait
> timeout. We didn't change checkout in today's release. Can the DB team look?

> **#warehouse, 10:46** — Dashboard is slow since this morning but works.
> Also: I started a stock correction for the Tallinn delivery earlier, then
> got pulled into a meeting. Is that related?

### Rules of engagement

This is production. Act like it.

- **Do not stop or restart the shop application.** It is the business. (The
  check fails if `<project>-shop-app` is not running.)
- **Do not restart `primary` or `replica`** unless you can explain in your
  review why nothing less disruptive would do.
- **Do not rebuild the replica from scratch.** It would work, but it takes
  hours on the real data set; repair it.
- **Do not change the built-in accounts** (`root`, `repl`, `app`,
  `exporter`).
- **Keep a log.** Every observation and every change, with UTC time, in a
  text file. It becomes the timeline of your review.
- Each scenario has a reference fix in `labs/scenarios/10-final-incident/solve.sh`.
  Do not open it until you are done.

### Deliverables

1. Impact stopped for all three symptoms, and the underlying causes fixed:
   `./lab check 10-final-incident` passes.
2. Your incident log (timestamps, observations, actions).
3. A post-incident review written from
   [docs/templates/postmortem.md](../../../docs/templates/postmortem.md).
4. A self-assessment against the [rubric](rubric.md).

Time-box yourself: 60 minutes for the incident, 60 for the review. Being
slower is fine; knowing that you were slower, and why, is part of the review.

<!-- founder-review: a short note from the course author on how a real
multi-fault incident felt from the inside would set the tone here -->

## Further reading

- [Managing Incidents](https://sre.google/sre-book/managing-incidents/) and
  [Postmortem Culture: Learning from Failure](https://sre.google/sre-book/postmortem-culture/),
  Google SRE book.
- [Postmortem Culture](https://sre.google/workbook/postmortem-culture/),
  Google SRE workbook — with an annotated example review.

## Next

Open the [exercise](exercise.md) and start the incident. When you are done,
assess yourself with the [rubric](rubric.md).
