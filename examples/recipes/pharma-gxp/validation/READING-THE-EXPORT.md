# Reading an audit export: an inspector's guide

Every record on the ledger has an audit export: one JSON file holding the record's chain of
signed entries, oldest first. A batch release is a handful of them (the release, its
precondition check, the proposal, the write receipt), and a complaint case is the case and
one export per dataset read. This guide is how to verify them and what to read in each.

## What to ask the site for

1. The audit exports for the batch or the complaint, taken with `?evidence=true` so each
   completion entry carries the body that was submitted:
   `GET /v1/records/{id}/audit-export?evidence=true` for the release or case, each of its
   children, the proposal and the receipt.
2. The Server's verification keys (`GET /v1/verification-keys`), as a file.
3. The vault signing key pin: a `sha256:` digest the installer printed when the Server was
   installed. The site should hold it somewhere other than the Server. It is not secret.
4. The case manifest, if the site ran the cross-record check (`oq/crosscheck.py`).

## Verify before you read

    agledger-verify <export>.json --keys verification-keys.json \
        --require-supplied-keys --trust-anchor sha256:<the pin>

The verifier (`@agledger/verify`, 2.1.0 or later) runs offline and needs no route to the
Server. Its first line is one of three:

| First line | Meaning |
|---|---|
| `[PASS]` | Every entry's signature was checked under a key that the signed key statements link to the pin you gave. |
| `[VERIFIED, NOT ANCHORED]` | Nothing failed, but no pin was given, so the keys were taken on the word of the files. Ask for the pin and run it again. |
| `[FAIL]` | The chain, a signature or a key does not hold. The findings are listed. A wrong pin fails here too. |

Below it, read `entries` (every entry verified), `key provenance` (`embedded=0`: no key was
taken from inside the export) and `evidence bodies` (each inlined body hashed to the
`evidenceHash` its entry signs).

## What is signed and what is display

The verifier's last note names three fields that are convenience labels resolved when the
export was taken and are not covered by the signature: `actorDisplayName`, `actorOwnerType`
and `humanReadableLabel`. Read identity from `actorOwnerId` (the agent or org whose
credential acted) and `actorRole`, which are. Who holds that agent's credential is the
site's provisioning record, not the ledger's.

## A released batch, entry by entry

The release record (`calder-batch-record-release-v1`):

| # | `entryType` | Actor | What to read |
|---|---|---|---|
| 1 | `RECORD_CREATED` | QA | `payload.principalAgentId` is QA, `performerAgentId` the proposer. `criteria`: the proposal and its hash, the lot and quantity, `requiredChecks` and the control plan's reference and hash, `checkerAgentId`, `maxCheckAgeMinutes`. |
| 2 | `RECORD_PROPOSED` | QA | QA offers the release to the proposer. |
| 3 | `RECORD_ACCEPTED` | proposer | `respondedByAgentId`: the proposer's consent, before any work. |
| 4 | `RECORD_STATE_CHANGE` | QA | `newStatus: ACTIVE`. |
| 5 | `COMPLETION_SUBMITTED` | proposer | `completionId`, `evidenceHash`, and the body in `evidence`: `checkRef` (the check it relies on) and `payloadHash` (what will be written). |
| 6, 7 | `GATE_STARTED`, `GATE_COMPLETE` | platform | The engine's rule result, with `advisory: true`: on this type the engine advises and QA decides. |
| 8 | `GATE_HELD` | platform | `status: PROCESSING`: waiting for QA's verdict. |
| 9 | `OUTCOME_REPORTED` | QA | The signature. `outcome: accept`; `checks` carries the meaning, the signer's name and role, the regulation and the signer's time; `completionId` is the completion signed (entry 5); `reporterType: principal` and `reporterId` is QA. `actorOwnerId` must equal `principalAgentId` from entry 1: an org administrator can render a verdict for a principal, and the entry would then name the administrator. |
| 10 | `RECORD_STATE_CHANGE` | QA | `newStatus: FULFILLED`. |

The precondition check (`calder-precondition-check-v1`) named by `checkRef`:

| # | `entryType` | Actor | What to read |
|---|---|---|---|
| 1 | `RECORD_DELEGATED` | proposer | `parentRecordId` is the release; `performerAgentId` is the checker and must equal the release's `checkerAgentId`; `criteria` carries the plan's reference and hash, equal to the release's, and no list of checks. |
| 2, 3 | `RECORD_STATE_CHANGE` | proposer | Activated at creation (`acceptanceBypassed: true`). |
| 4 | `COMPLETION_SUBMITTED` | checker | The body: the plan as the checker read it, and every check with its source record, what the system answered, what was expected and whether it passed. |
| 5, 6 | `GATE_STARTED`, `GATE_COMPLETE` | platform | The rule result, `advisory: false`: here the engine decides. |
| 7 | `RECORD_STATE_CHANGE` | platform | `newStatus: FULFILLED` or `FAILED`. |

The proposal and the receipt are one entry each (`RECORD_CREATED`, status `RECORDED`): the
proposal under the proposer's identity, the receipt under the writer's, with the system of
record's id, name and write stamp and the same `payloadHash` QA approved.

## A release that was refused

When the check fails, the release has no completion from the proposer. After entry 4 it
reads `CASCADING_GATE_STARTED` and `CASCADING_GATE_COMPLETE` (the failed child, `aggregateOutcome:
reject`), `GATE_HELD`, `OUTCOME_REPORTED` with `outcome: reject` and QA's meaning, and
`RECORD_STATE_CHANGE` to `FAILED`. No receipt names the release. A later `REVISION_REQUESTED`
entry means the rejected release was reopened; the site's SOP says whether that is ever
allowed over a failed check.

A check that was cancelled reads `CANCELLED` either way; the state-change entry says which.
`CANCELLED_PRE_WORK` means it was cancelled before the checker was engaged and did not hold
the release. `CANCELLED_IN_PROGRESS` fails the release as a failed check does.

## A complaint case

The case (`calder-complaint-case-v1`) reads like the release: created by the QA
investigator, accepted by the orchestrator, completed with the close-out (the 211.198
decisions, `evidenceRecordIds`, the write-stamp digest), signed by the investigator's
verdict. Each read (`calder-evidence-read-v1`) reads like the check: delegated by the
orchestrator to one reader, completed by that reader with the query hash, the result hash,
the source records with the system's own write stamps and `mutating`, and settled by the
engine. A read that wrote settles `FAILED` and the case then reads like a refused release.

## What takes more than one export

The engine does not read one record from inside another. These comparisons span exports,
and `oq/crosscheck.py` makes all of them from the files alone:

- `checkRef` names a `FULFILLED` check that is a child of this release, settled before the
  release completion was submitted.
- That check's performer is the release's `checkerAgentId`.
- The check was no older than `maxCheckAgeMinutes` at the release completion, at the
  signature and at the receipt.
- The check's plan reference and hash, and the plan as the checker read it, equal the
  release's.
- The release's proposal hash, product, lot and quantity equal the proposal's.
- The receipt's `payloadHash` equals the release completion's, and the receipt was written
  after the signature.
- The close-out's `evidenceRecordIds` are the case's reads, and its write-stamp digest
  re-derives from the stamps those reads listed.

## What the export does not tell you

- Whether the systems answered what the evidence says. Each check and each read names its
  source records; compare them, and the write stamps, to the system's own audit trail.
- Whether anything was done outside the ledger. The read-only claim for a complaint rests
  on the stamps and on the system's own log for the window between read and close.
- Who a signer is beyond the agent id. `signerName` is text the caller supplied.
