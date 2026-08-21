# Agent Work Context: AGLedger horizontal recipe

Durable work state for AI agents, checkpointed as immutable signed records, so
a fresh session with no prior conversation resumes or takes handoff of
in-progress work. One contract type and a small convention set. Unlike the
vertical recipes in this directory, this one is domain-neutral: it scaffolds
HOW agents carry work state, not WHAT the work is.

> **How to use this recipe:** it is a tested **reference scaffold**, not a
> turnkey product. The type and the conventions were validated against a live
> server and against cold-start model runs; the work content, field depth, and
> key policy you wire around it are yours.

> **What AGLedger does here:** notarizes each checkpoint, attributed and
> tamper-evident, and holds the lineage as signed content. It does **not**
> verify that a checkpoint's claims are true. What the chain gives you is that
> claims are *checkable*: a checkpoint that says "notarized the decision"
> either has the decision record under the same root or it does not.

## The identity model (read this first)

A registered AGLedger agent is a durable identity. The **sessions** that do
its work (different models, harnesses, runs) are ephemeral; the server sees
only the key a session connects with, and the key's owner binding names the
agent. "A fresh agent resumes the work" means a new session of the SAME
agent:

- **Resume**: the new session presents the agent's existing key.
- **Handoff with visible succession**: mint an additional key bound to the
  same agent for the successor session (`POST /v1/admin/api-keys`,
  admin-mediated). The vault's signed attribution is two-level,
  `actorOwnerId` (agent) and `actorId` (key), both inside the signature, so
  succession is tamper-evident and each successor is independently revocable.
- Plain key reuse also works but leaves succession unrecorded in the chain.
- **Agent isolation is structural**: a key bound to a different agent can
  neither read nor continue the work (structural-role refusals, caller-scoped
  lists, self-assignment-only delegation). The boundary is the agent's keys,
  and key minting is admin-mediated, so the org admin is inside that boundary.

## Shape

```
delegated-workflow-v1 (root; seeded starter, notarize-only)
  criteria.workflowName  = the work
  criteria.workContext   = navigation hint (see below)      <- load-bearing
    |
    +-- work-context-v1 (checkpointReason: initial)
    +-- work-context-v1 (supersedes the initial)
    +-- work-context-v1 (supersedes the previous head)       <- head = nothing supersedes it
    +-- ... siblings, never children of each other
    +-- notarize-generic-v1 / your types: work artifacts, decisions
```

- **One root per piece of work.** Every checkpoint is a CHILD of the root via
  `parentRecordId`. Siblings, never chained checkpoint-to-checkpoint: the
  delegation depth cap (default 5) kills a naive chain at its 6th link, and
  nothing warns earlier.
- **Head = the checkpoint nothing supersedes**, one call:
  `GET /v1/records/search?parentRecordId=<root>&type=work-context-v1&superseded=false`.
  Prefer this over reading the newest row: on an append-only ledger every state
  a piece of work ever held keeps matching a filter forever, so
  `&criteria[state]=blocked` without `&superseded=false` returns work that was
  unblocked three checkpoints ago. It also tells the truth about forks by
  returning two rows instead of picking one (see below). Drop
  `&parentRecordId=` to sweep every piece of work at once, which is how a
  resuming session triages a portfolio in one call rather than one call per
  root.
- **The root carries the map.** Put this in the root's criteria (the schema
  accepts extra fields); cold-start models read the root first and some never
  read schema descriptions:

  ```json
  "workContext": "Durable work state lives in work-context-v1 CHILD records of this root. Head = the one nothing supersedes: GET /v1/records/search?parentRecordId=<thisRecordId>&type=work-context-v1&superseded=false. Read the head, then follow its resumeInstructions. When you write your own checkpoint, pass the head's id as the top-level supersedesRecordId field on POST /v1/records (a record field, not a criteria field). Omit it and the old head stays current, so the next session sees two heads."
  ```

- **Supersession is a record field, not criteria.** Pass `supersedesRecordId`
  at the top level of `POST /v1/records`, naming the head you read. The engine
  resolves the target and refuses the create with 404 if it does not exist in
  your org, so a checkpoint can never carry a dangling lineage claim onto the
  chain. It is inside the create-time signature and immutable, so an offline
  verifier rebuilds the same lineage the API reports. `final` requires empty
  `pendingWork`, enforced in-schema.

  The first checkpoint (`checkpointReason: "initial"`) supersedes nothing.
  Omitting `supersedesRecordId` on a later one is not a 400: the head you
  failed to supersede stays un-superseded, so the head query returns both rows
  on the very next read. That catches the omission, which a refusal on a
  MISSING claim also caught, and it additionally catches a WRONG one.

  Zero rows back is its own condition, and it is not always "no checkpoints
  yet": if this root's only head was superseded by a checkpoint written under a
  different parent, the view empties for good. The response's `nextSteps` says
  which of the two it is, and dropping `&superseded=false` settles it in one
  call.

  Two rows back is one signal for two different conditions, and the counts are
  what separate them. Read `supersedesRecordId` on both rows: if they name the
  SAME record (`supersededByCount: 2` on it), two writers raced over one head
  and you have a genuine fork to merge. If one of them supersedes nothing, that
  writer omitted the field and the old head simply stayed current; write the
  next checkpoint superseding the row you keep. "Neither row supersedes the
  other" is true in both cases and tells you nothing.
  `verify-lineage.py` makes the same distinction: `every non-initial checkpoint
  supersedes something` fails on the omission, `no record superseded twice
  (fork)` fails on the fork.

## Lineage coherence is the client's job (and the tool that does it)

The server resolves `supersedesRecordId` (a create naming a record outside your
org is refused), but it does not judge whether the lineage makes sense for this
recipe. All of the following land as ordinary 201s that verify clean offline:

- **A fork**: two sessions of the same agent resume concurrently, both read
  the same head, both write successors superseding it. Both land, and the head
  query returns **both**, with `supersededByCount: 2` on the record they
  raced over. That is the intended behaviour: there really are two branches,
  and picking one for you would be the engine inventing an answer.
- A checkpoint superseding one under a **different root**. Read the reader-side
  cost before you shrug at this one: supersession is global and the head query
  is scoped to direct children of a parent, so the successor is not in the
  other root's view and the head it replaced is superseded by something that
  view cannot see. If that root held no other current checkpoint, its
  `&superseded=false` query returns **zero rows, permanently**, which looks
  exactly like a piece of work with no checkpoints yet. The engine now says so
  on both sides: the create response carries a `nextSteps` entry naming the
  parent whose view it just emptied, and the empty head query carries one
  saying how many rows match without the flag and pointing at
  `?supersedesRecordId=`, which is the only surface that finds the successor.
  Run against the WRITING root, `verify-lineage.py` reports it as
  `every supersedesRecordId resolves under this root` (or, when the writer was
  that root's first checkpoint, as `the initial checkpoint supersedes
  nothing`, the likeliest shape, since a session opening work on a new root is
  the one holding a head id read from somewhere else); run against the emptied
  one it reports nothing, because from there the tree looks coherent and simply
  ends.
- A **second `initial`** under one root.

`verify-lineage.py` (this directory) walks the whole tree: given a root id it
fetches every checkpoint (cursor pagination) and proves exactly one initial,
that initial supersedes nothing, every non-initial supersedes something, every
supersedes resolves under the root, no record superseded twice, a single chain
covering all checkpoints, and terminus == head-query answer. The head query alone tells you THAT the tree
forked; this tells you where. Run it at every resume if two sessions of the
same agent can run concurrently in your deployment.

A detected fork is not tamper: every branch is genuinely signed by the agent.
Recover by writing a new checkpoint that supersedes the branch you keep and
records the merge; never try to un-write the other branch.

Concurrency detail worth knowing: `createdAt` ordering is **server** time, and
under same-millisecond concurrent writes it can invert the order the ids were
minted in (UUIDv7 timestamps), so two racing sessions can each believe they
wrote the newest checkpoint. This is exactly why the head query filters on
`superseded=false` rather than taking the newest row: supersession is a claim
the writer signed, so it does not depend on whose clock won.

## Registration

Two paths; pick ONE per org:

- `./register.sh` registers `types/01-work-context.json` via
  `POST /v1/schemas` (an admin key with `schemas:write`; the default
  `admin-standard` profile carries it). Lands under the `local` publisher.
- `manifests/01-work-context.json` is the importable body for
  `POST /v1/schemas/import` (publisher `agledger-recipes`). Use it when you
  want the type distributed across servers with a matching `manifestDigest`,
  so peers can confirm schema equality by digest instead of by name.

Do not do both on one org: two publishers offering `work-context-v1` makes a
bare `type` ambiguous (422 on every record create until callers pin
`publisher`).

## Checkpoint size: the working rule

- A useful working checkpoint is **2 to 4KB** of criteria. In cold-start
  runs, a 1.7KB head was resumed correctly by every model that completed the
  protocol; against a ~10KB head one model read state, did the first pending
  item, and wrote no successor.
- The server enforces a criteria size cap, so an unbounded head eventually
  refuses to grow. Staying in the 2 to 4KB range keeps you clear of it and,
  more importantly, keeps the head readable by small models.
- `references`: max 25 entries, `{system, refType, refId}` required, no hash
  field; carry a digest in `attributes` (max 10 keys / 4KB) by convention.
- **Snapshot, do not append.** Superseded checkpoints stay on-chain forever,
  so the head does not need the full history: keep `completedWork` to the
  recent working set, summarize older progress in `summary`, and let the
  supersedes chain BE the archive. An instructed model compacts naturally.
- When a pending item creates a record, have the successor checkpoint carry
  the created record id (in `completedWork` text or `evidence`). That turns
  "I did it" into a machine-checkable claim: in cold runs a small model
  fabricated exactly this claim, and the record-id convention is what makes
  that checkable.

## What cold-start runs taught us

The conventions above were shaped by running fresh model contexts (no prior
conversation, one generic HTTP tool, a brief of base URL + agent key + root id
+ type name) against a live server:

- **The schema guard held in every failed run.** No model produced a fork or
  a stale-head successor; failures were incomplete runs, not corrupted
  lineage.
- **The failure mode that survives the guard is a false claim.** A checkpoint
  can correctly supersede the head while claiming work that never happened;
  two runs of a small model wrote `completedWork` entries for a notarization
  that did not occur. Unchecked, that silently drops the item from
  `pendingWork`. This is why created-record ids belong in checkpoints.
- **Head size matters more than model size** for resume fidelity: every model
  that completed the protocol on a compact head resumed correctly; large
  heads produced partial resumes.

## A2A

The server speaks A2A 0.3 and 1.0 on `/a2a` (dialect via the `A2A-Version`
header), and an A2A-native session can hold an agent's key. The recipe drives
from either door, and the fields below are covered by integration tests on
both dialects:

- **The whole spine drives over A2A.** `create_record` carries both
  `parentRecordId` and `supersedesRecordId`, so a checkpoint lands under the
  root and retires the head it replaced in one call. The Task's metadata
  reports the result (`agledger:parentRecordId`, `agledger:supersedesRecordId`,
  `agledger:supersededByCount`), so a writer can tell a live head from a
  record something already replaced without a REST read.
- **The head query is `ListTasks`** with
  `filter: 'parentRecordId = "<root>" AND type = "work-context-v1" AND superseded = false'`.
  Same answer as the REST head query, same reason for the `superseded` term:
  do not read `tasks[0]` instead, which is the newest row rather than the
  current one.
- **The in-schema guards carry over** (the `checkpointReason` enum, `final`
  requiring empty `pendingWork`), refused with the full `google.rpc.ErrorInfo`
  envelope (detail, validationErrors, schemaUrl). So does the create-time
  resolution of `supersedesRecordId`: a target outside your org is a refusal,
  not a dangling claim on the chain.
- **What A2A still does not carry** is `references`, `metadata`, `dependsOn`
  and `riskClassification`, so a fleet that wants A2A task ids checkable from
  the chain writes those checkpoints over REST. Nothing else about the recipe
  changes with the door.

## Limits

- Offline verification (audit-export) covers per-record chain crypto; lineage
  semantics are the client-side check described above, and
  `verify-lineage.py` needs the server (head query), so a fully offline
  auditor has to walk the exported criteria themselves.
- Nothing steers an agent that ignores both the root hint and the schema
  description; write the root's `workContext` hint every time.
- Exercised at 150 checkpoints under one root: sibling creation never hits
  the delegation depth cap, the head is still one call (`data[0]` of page 1,
  default page size 50, max `limit` 100, cursor pagination), and the lineage
  check walks all pages in tens of milliseconds against a local server.
  Sustained creation does meet the default agent rate limit (500/min; the
  429 carries `retryAfterSeconds`). Months-long work items with thousands of
  checkpoints remain unexercised.
- Succession attribution is byte-level verifiable: the actor key id and the
  agent id ride as CWT claims in the COSE protected header, which the Ed25519
  signature covers. Two checkpoints from two sessions of one agent differ in
  key id and agree on agent id.
