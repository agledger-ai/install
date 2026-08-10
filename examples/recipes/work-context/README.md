# Agent Work Context: AGLedger horizontal recipe

Durable work state for AI agents, checkpointed as immutable signed records, so
a fresh process with no prior conversation resumes or takes handoff of
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

A registered AGLedger agent is a persistent **seat**. The processes that
occupy it (different models, harnesses, runs) are ephemeral **occupants**; the
server sees only the key they connect with, and the key's owner binding names
the seat. "A fresh agent resumes the work" means a new occupant of the SAME
seat:

- **Resume**: the new occupant presents the seat's existing key.
- **Handoff with visible succession**: mint an additional key bound to the
  same seat for the successor process (`POST /v1/admin/api-keys`,
  admin-mediated). The vault's signed attribution is two-level,
  `actorOwnerId` (seat) and `actorId` (key), both inside the signature, so
  succession is tamper-evident and each successor is independently revocable.
- Plain key reuse also works but leaves succession unrecorded in the chain.
- **Seat isolation is structural**: a key bound to a different agent seat can
  neither read nor continue the work (structural-role refusals, caller-scoped
  lists, self-assignment-only delegation). The boundary is the seat's keys,
  and key minting is admin-mediated, so the org admin is inside that boundary.

## Shape

```
delegated-workflow-v1 (root; seeded starter, notarize-only)
  criteria.workflowName  = the work
  criteria.workContext   = navigation hint (see below)      <- load-bearing
    |
    +-- work-context-v1 (checkpointReason: initial)
    +-- work-context-v1 (supersedes the initial)             <- head = newest
    +-- work-context-v1 (supersedes the previous head)
    +-- ... siblings, never children of each other
    +-- notarize-generic-v1 / your types: work artifacts, decisions
```

- **One root per piece of work.** Every checkpoint is a CHILD of the root via
  `parentRecordId`. Siblings, never chained checkpoint-to-checkpoint: the
  delegation depth cap (default 5) kills a naive chain at its 6th link, and
  nothing warns earlier.
- **Head = newest checkpoint**, one call:
  `GET /v1/records/search?parentRecordId=<root>&type=work-context-v1`
  (newest first).
- **The root carries the map.** Put this in the root's criteria (the schema
  accepts extra fields); cold-start models read the root first and some never
  read schema descriptions:

  ```json
  "workContext": "Durable work state lives in work-context-v1 CHILD records of this root. Head = newest one: GET /v1/records/search?parentRecordId=<thisRecordId>&type=work-context-v1 (newest first). Read the head, then follow its resumeInstructions."
  ```

- **Lineage is schema-enforced.** The first checkpoint uses
  `checkpointReason: "initial"`; every later checkpoint MUST carry
  `supersedesRecordId` (400 otherwise). This is the highest-value guard in
  the recipe: a resumer that misidentified the head gets a refusal instead of
  silently forking the chain with a stale head. `final` requires empty
  `pendingWork`, also in-schema.

## Lineage coherence is the client's job (and the tool that does it)

The server notarizes what it is told; `supersedesRecordId` is signed content,
not checked semantics. All of the following land as ordinary 201s that verify
clean offline:

- **A fork**: two occupants resume the same seat concurrently, both read the
  same head, both write successors superseding it. Both land. The head query
  silently returns whichever got the later server timestamp; the other branch
  is invisible unless you look for it.
- A `supersedesRecordId` naming a **nonexistent record**, or a checkpoint
  under a **different root**.
- A **second `initial`** under one root.

`verify-lineage.py` (this directory) is the check the schema guards cannot
provide: given a root id it fetches every checkpoint (cursor pagination) and
proves exactly one initial, every supersedes resolves under the root, no
record superseded twice, a single chain covering all checkpoints, and
terminus == head-query answer. Run it at every resume if concurrent occupancy
is possible in your deployment.

A detected fork is not tamper: every branch is genuinely signed by the seat.
Recover by writing a new checkpoint that supersedes the branch you keep and
records the merge; never try to un-write the other branch.

Concurrency detail worth knowing: the head query orders by **server**
`createdAt`. Under same-millisecond concurrent writes this can invert the
order the ids were minted in (UUIDv7 timestamps), so two racing occupants can
each believe they wrote the newest checkpoint. The lineage check is what
turns that race from silent divergence into a visible fork.

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
conversation, one generic HTTP tool, a brief of base URL + seat key + root id
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
header), and an A2A-native process can hold a seat's key. Probed live against
this recipe on both dialects:

- **On current releases the spine is REST-only.** The A2A `create_record`
  action does not carry `parentRecordId`, and no A2A action answers the head
  query, so checkpoints cannot be written under a root or found from A2A.
- **The schema guards do carry over**: a non-initial checkpoint without
  `supersedesRecordId` sent via A2A is refused with the full
  `google.rpc.ErrorInfo` envelope (detail, validationErrors, schemaUrl), so
  the highest-value guard is dialect-independent.
- **The pattern that works is hybrid**: agents coordinate over A2A; whichever
  occupant holds the seat writes and reads checkpoints over REST with the
  seat's key. Put the work-context ROOT id in the A2A task or message
  metadata so a fleet coordinating over A2A can find the ledger tree, and
  record A2A task ids in checkpoint `references`
  (`{system: "a2a", refType: "task", refId: <taskId>}`) so the A2A side of a
  handoff is checkable from the chain.

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
  seat id ride as CWT claims in the COSE protected header, which the Ed25519
  signature covers. Two checkpoints from two occupants of one seat differ in
  key id and agree on seat id.
