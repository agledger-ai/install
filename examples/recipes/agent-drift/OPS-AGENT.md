# Ops agent brief: what to do with a drift tick

This is the half of the loop that judges. `drift-triage.py` runs on a schedule
and hands you one dossier per tick (`tick.json`). The engine's drift series
carries no score, no weighting and no threshold, on purpose: a change is a
change, and whether it is good is your call as the principal watching the
fleet. Nothing below tells you a direction is bad.

## Inputs

`tick.json` holds `window` (the two date ranges), `fleet` (how many agents
exist, how many series came back, how many were idle in both windows), and
`movers`, one entry per agent whose numbers moved. Each mover carries:

- `class`: `new` (active now, idle in the baseline), `quiet` (idle now, active
  in the baseline) or `shifted` (active in both, numbers differ).
- `movedCounts`, `acceptanceRate` and `medianCompletionMs`: which numbers moved
  and from what to what. `current`, `baseline` and `change` are the engine's
  own series, untouched.
- `byType`: the same counts per contract type, so a shift can be placed on the
  type where it happened.
- `historyCurrentWindow`: the records behind the current-window counts (a
  summary by type, status, role and outcome, plus a sample of rows). Read the
  records, not just the counts, before deciding anything.

## What you do with each mover

Decide one of three things, and write the reason down:

1. **Expected.** The change has an explanation you can name from the dossier:
   a new agent onboarding (`new`), a decommissioned one (`quiet`), a type that
   was introduced or retired, a volume change that matches a known event.
   Record it and move on.
2. **Watch.** You cannot explain it yet, and nothing in the records is wrong on
   its face. Re-check on the next tick; a `shifted` agent that keeps shifting
   in the same direction over several ticks is a different situation from one
   that moved once.
3. **Escalate.** Something in the records is wrong on its face (verdicts
   rejected where they used to be accepted, a type the agent should not be
   touching, completions that vanished while records kept coming), or a
   `quiet` agent that should not be quiet. Hand the dossier to a person with
   what you saw and what you did not check. Do not act on the key or the agent
   yourself from this loop; the loop observes.

Two rules that hold whatever you decide:

- **Never decide from the number alone.** `acceptanceRate` 0.8 to 1.0 is a
  mover exactly as 0.8 to 0.6 is. The first can be a principal who stopped
  reading before accepting; the second can be a performer who is finally being
  reviewed. The history rows say which.
- **`change.acceptanceRate` is null when either window has no verdict.** An
  agent that went from no gated work to all-accepted gated work shows up with
  a null change and a real shift. The triage tool selects on the two window
  values, not on `change`; do the same when you read the raw series.

## Write the decision to the ledger

The loop is itself automated work, so its decisions belong on the same ledger
it watches. Notarize each tick as a `notarize-generic-v1`
record carrying the tick's digest and the mover ids. Add your decisions to
that pattern: one record per tick with `criteria.decisions` as a list of
`{agentId, decision: expected|watch|escalate, reason}`. An auditor can then
answer "what did the ops agent see on the 14th and what did it do" from an
offline-verifiable export, without trusting the ops agent's own logs.

The write is one call, and the type's schema requires a `summary`:

```
POST /v1/records
{"type": "notarize-generic-v1",
 "criteria": {"summary": "drift tick <tickAt>: <n> movers, <k> escalated",
              "tickDigest": "sha256:<sha256 of tick.json>", "window": 7,
              "decisions": [{"agentId": "...", "decision": "escalate", "reason": "..."}]}}
```

On an agent key nothing else goes in the body: the key names the principal. The
loop as shipped runs on the operator's admin key (an agent key can read its own
series but a sibling's drift, history and capabilities answer 403 and its
profile 404), and on an admin key the body also carries
`"principalAgentId": "<the ops agent's id>"` so the record is yours. Models
handed this brief without the shape above found the write only after a 404 on a
path without `/v1` and a 400 on an invented body field, so the shape is written
out here.

## Scheduling

Pick `--window` to match the cadence of the question, not of the cron:

- Daily tick, `--window 1`: today against yesterday. Noisy for agents that do
  a handful of records a day; every count moves.
- Daily tick, `--window 7`: the trailing week against the week before. Smooths
  daily noise, lags a real change by up to a week.
- Weekly tick, `--window 7` or `--window 30`: the review cadence most fleets
  want.

Windows are whole days (engine minimum 1), so an hourly loop cannot see
hour-over-hour change; it sees the same day-granular series eleven more times.
