# Agent drift: an ops loop over the fleet

A horizontal recipe: how an admin uses `GET /v1/agents/drift`. The endpoint
gives one series per agent (what it did in the current window, what it did in
the window before, and the difference) and deliberately stops there: no score,
no threshold, no flag. This recipe is the loop that turns that series into
something an operator acts on, split into the half that is deterministic and
the half that judges.

It is a starting point, not a turnkey product: the selection rule and the
schedule are choices, stated below, and you will change them.

There are no contract types to register. The loop writes its decisions as
`notarize-generic-v1` records, which every org is seeded with.

## Files

| File | What it is |
|------|------------|
| `drift-triage.py` | The deterministic half. About 150 lines of standard-library Python, no SDK. Pages the fleet, selects the agents that moved, pulls the per-type series and record history for each, and writes one JSON dossier per tick. |
| `OPS-AGENT.md` | The judging half: the brief you hand to whichever model or person decides what each mover means, including the exact call that writes the decision to the ledger. |

## The loop

```
cron / scheduler
   |
   v
drift-triage.py --window 7 --json tick.json         (deterministic)
   |  1. page GET /v1/agents/drift for the whole fleet
   |  2. select the agents whose numbers moved, either direction
   |  3. per mover: GET /v1/agents/{id}/drift (byType)
   |               GET /v1/agents/{id}/history?from=&to= (the records)
   v
tick.json  ->  the ops agent (OPS-AGENT.md)          (judges)
   |  expected | watch | escalate, with a reason, per mover
   v
POST /v1/records notarize-generic-v1                  (the tick on the ledger)
   criteria: {summary, tickDigest, window, decisions}
```

## Run

```bash
export AGLEDGER_API_URL=https://agledger.example.com
export AGLEDGER_API_KEY=agl_...   # org-bound admin key; needs drift:read
python3 drift-triage.py --window 7 --json tick.json
```

`drift:read` is carried by both the admin-standard and admin-observer
profiles. The script prints a short summary and writes the dossier; hand
`tick.json` and `OPS-AGENT.md` to the judging half.

An agent key is not enough to run the loop: it can read its own series, but a
sibling's drift and history answer 403.

## What the endpoint gives you, and what it does not

Per agent, for both windows: `records`, `completions`, `verdicts`,
`accepted`, `rejected`, `overturned`, `acceptanceRate` (null with no verdict)
and `medianCompletionMs` (null with no completion). `change` is current minus
baseline, field by field, and is null where either side is null. Everything
is computed on read from the records themselves, by the time each happened.
`GET /v1/agents/{id}/drift` adds the same series per contract type;
`GET /v1/agents/{id}/history` is the record feed behind the counts, with
`from`/`to` so a window can be read back exactly.

What it does not carry, and what the recipe therefore supplies:

- **No filter for "changed only" and no sort.** Every tick walks the whole
  fleet, 100 series per call. An org of a few hundred agents is a handful of
  calls; one of 5,000 is fifty per tick.
- **No threshold.** The recipe's rule: any count that differs selects the
  agent; an acceptance rate that differs selects it (0.8 to 1.0 counts, as the
  endpoint's own description says); the median completion time selects only
  when it moved by a factor (`--median-ratio`, default 2x), because a
  millisecond median moves on every tick for any agent that completed
  anything. Idle in both windows never selects.
- **`change.acceptanceRate` is null when either window has no verdict**, so
  an agent that went from no gated work to all-accepted gated work has a real
  shift and a null change. The script compares the two window values, not
  `change`.
- **Windows are whole days** (`window` 1 to 365, default 7). An hourly loop
  sees the same day-granular series each hour.

## Selection classes

| class | meaning |
|---|---|
| `new` | active in the current window, idle in the baseline |
| `quiet` | idle in the current window, active in the baseline |
| `shifted` | active in both, and a count, the acceptance rate or the median moved |

Each mover's dossier carries the raw series, the per-type series and the
current-window record feed (summary by type, status, role and outcome, plus a
sample of rows, capped by `--history-limit`). The judging half reads the
records, not the counts.

## Trying it on a fresh install

Drift needs two windows of activity, and a fresh install has one. A customer
migrating history can place records in the baseline window with the backfill
import (`POST /v1/admin/records/import`, platform key, `admin:backfill`) and a
backdated `createdAt`. Imported records count toward `records`, but an
imported record's verdict is not counted by drift and reads `PENDING` in the
history feed, so an acceptance-rate shift cannot be staged through the import.
Volume shifts (`new`, `quiet`, a changed record count) can.

## What it does not do

- The loop observes; it does not act on keys or agents. Escalation is to a
  person with the dossier (see the brief).
- Selection is one tick against one baseline. Trend across ticks is the ops
  agent's memory, or the ledger's: each tick is a record, so the trend can be
  read back from `GET /v1/records?type=notarize-generic-v1` filtered on the
  ops agent.
- The engine counts an agent's own acts. A record where the agent is principal
  and another agent is performer is in the performer's series, and in the
  principal's history feed as `role: principal`; the history summary shows the
  role split so that is visible.

## Verifying the ticks

Each tick record exports like any other (`GET /v1/records/{id}/audit-export`)
and verifies offline with `agledger-verify` against your Server's
verification keys. That is what lets an auditor check what the ops agent saw
and decided on a given day without trusting the ops agent's own logs.
