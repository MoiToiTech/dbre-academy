# Post-incident review: [short title]

<!--
A blameless post-incident review (postmortem). Copy this file, fill it in,
delete the guidance comments. It describes what the system and the people
in it did, and why that made sense at the time; it does not ask who is at
fault. Background: Google SRE book, "Postmortem Culture: Learning from
Failure" — https://sre.google/sre-book/postmortem-culture/
-->

| Field | Value |
|---|---|
| Status | Draft / In review / Final |
| Severity | SEV1 / SEV2 / SEV3 |
| Incident window | YYYY-MM-DD HH:MM – HH:MM UTC |
| Authors | |
| Incident commander | |
| Reviewers | |

## Summary

<!-- Three to five sentences a manager can read on a phone: what broke, who
was affected, for how long, what fixed it, and the one thing that most
needs to change. -->

## Impact

<!-- In numbers, with the source of each number. Users or requests affected,
error rate, duration, data affected (lost, stale, inconsistent), money or
SLO budget spent. Say what you could not measure. -->

| Measure | Value | Source |
|---|---|---|
| Duration of user impact | | |
| Requests failed or degraded | | |
| Data loss or inconsistency | none / describe | |
| Error budget consumed | | |

## Timeline

<!-- UTC, one line per event, facts only. Include detection, every decision
and who made it, each mitigation and whether it worked, and the moment
impact ended. Copy commands and output from the incident channel. -->

| Time (UTC) | Event |
|---|---|
| HH:MM | First symptom (alert / ticket / customer report) |
| HH:MM | Incident declared, SEVn, IC: … |
| HH:MM | |
| HH:MM | User impact ended |
| HH:MM | Incident resolved |

## Detection

<!-- How did we find out, and how long after impact began? Did an alert
fire, and was it the right one? What signal would have caught it sooner? -->

## Response and mitigation

<!-- What was done to stop the impact, in order. For each step: what we
believed at the time, what we did, what happened. Note any step that was
risky or that made things worse, and why it looked reasonable then. -->

## Root cause and contributing factors

<!-- The technical mechanism, named precisely ("an idle session held next-key
locks on 50 inventory rows for 14 minutes", not "the database was slow").
Then the conditions that let it happen and let it last: missing guard
rails, missing alerts, unclear ownership, process gaps. There is rarely a
single root cause; list each fault separately if there were several. -->

## What went well

## What went badly

## Where we were lucky

<!-- Things that limited the damage but that we cannot rely on next time. -->

## Action items

<!-- Each item: specific, has one owner, a priority and a tracking link.
Prefer items that prevent recurrence or shorten detection over "be more
careful". Mark which item addresses which contributing factor. -->

| Action (prevent / detect / mitigate / process) | Owner | Priority | Tracking |
|---|---|---|---|
| | | P1 / P2 / P3 | |

## Lessons

<!-- What would you tell another team so they do not repeat this? -->

## Supporting material

<!-- Links to dashboards, query output, logs, the incident channel. Remove
customer personal data and secrets before sharing. -->
