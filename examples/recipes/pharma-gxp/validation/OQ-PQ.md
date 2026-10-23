# Operational and performance qualification

The OQ is a scripted run of both workflows against your own install, with every assertion in
`TRACEABILITY.md` made and logged. No script ships with the recipe; the assertions are its
specification. A quality team runs it, keeps the output, and files it
with the matrix and the intended-use statement. Nothing here is a certificate; it is the
evidence a site's own validation uses.

## OQ: what to script

Prerequisites: the types registered (`register.sh`), the system of record up and seeded
(`sor/setup.sh`, `sor/seed-sor.py`), one credential per role (QA investigator, orchestrator,
the readers, the proposer, QA release, the checker, the writer), `jq`, Python 3.11+, and the
published verifier (`agledger-verify`) for the offline checks.

Drive four cases and the negative probes, asserting each line of `TRACEABILITY.md` as you go:

1. **Complaint A, read-only.** QA opens the case naming the orchestrator; the orchestrator
   delegates the four reads as one-shot children (`maxSubmissions: 1`, a deadline); each
   reader completes with its evidence; the close-out is refused while a read is open and
   admitted once all are terminal; QA accepts with a signature meaning.
2. **Complaint B, a mutating reader.** As A, with one reader that wrote to a lot record and
   reports `mutating: true`. The read settles FAILED, the case is held by rollup, QA accept is
   refused, QA reject lands.
3. **Release C, clean.** The proposer notarizes a proposal on the passed component lot; QA
   opens the release from the control plan; the proposer delegates the check to the checker;
   `checker.py` runs against Odoo and the check settles FULFILLED; the proposer completes the
   release with the payload hash; QA accepts with a Part 11 signature meaning; `writer.py`
   writes the batch record; the writer notarizes the receipt; the manufacturing order exists
   in Odoo with the approved lot.
4. **Release D, a failed component lot.** As C on the failed lot. The check settles FAILED,
   the release is held, QA accept is refused, QA reject lands, and nothing was written to
   Odoo for the proposed lot.

The negative probes are the refusals the matrix lists: schema conditionals, the list on the
check child, the short, renamed, stale and failed check completions, the missing hashes,
binding of duty and circular delegation. Four more are things the engine admits and the
cross-record check must catch: a release completed with no check child; a check child
cancelled before work; a check child whose performer is the proposer; and a revision
requested on a release QA rejected over a failed check.

Export every record (`GET /v1/records/{id}/audit-export`), save the completion bodies beside
the exports (the export carries evidence hashes, not evidence), verify each export with
`agledger-verify` against `GET /v1/verification-keys`, corrupt one byte of one export and
confirm the verifier reports it, and run the cross-record checks, which the site writes (none
ship): the release completion's `checkRef` is a FULFILLED child of the release whose performer
is the expected checker; the checker's plan list and the check child's `controlPlanRef` and
`controlPlanHash` equal the release's; the close-out's `sorWriteStampDigest` re-derives from
the reads' `sourceRecords` and its `evidenceRecordIds` equals the case's children; the
receipt's `payloadHash` equals the release completion's; and every OUTCOME_REPORTED entry's
reporter is the principal's identity.

Log one line per assertion as `<requirement id><TAB><assertion>` and regenerate the matrix
from it:

    python3 validation/build-matrix.py oq-$(date +%Y%m%d).log

A requirement with no assertion is marked UNCOVERED in the table and the build exits
non-zero. The build overwrites `TRACEABILITY.md`, so run it on a copy of this directory or
keep the shipped matrix in version control.

## What the OQ does not cover

- The site's own systems. The reference automations drive the Odoo rig in `sor/`; a site that
  replaced `checker.py`, `readers.py` and `writer.py` with implementations against its MES,
  LIMS and ERP re-runs the OQ against those and keeps that log. The evidence shapes are the
  same.
- Identity binding. The signers in the reference run are API-key agents named for their
  roles. A site binds each to a person (OIDC workload identity, or key custody under its
  SOP); see "Binding a signer to a person" in the README.
- Retention and availability of the ledger (vault checkpoints, anchors, backups): the
  Server's operations runbook, not this recipe.

## PQ: run it as the site runs it

Performance qualification is the OQ's scenarios driven with the site's identities, data
and systems on the production-shaped install, under the SOP that will govern it:

1. Open one real complaint case with the QA investigator's own credential; let the site's
   readers attach their evidence; close it. Export the case and its children; verify the
   exports and run the cross-record checks.
2. Propose one real batch; open the release from the live control plan; let the checker run
   against the live systems; approve; confirm the batch record exists in the MES with the
   lot the receipt names and that the receipt's payload hash equals the approved one.
3. Repeat 2 with a component lot that must fail a check, and confirm that no batch record
   was created and that the release reads FAILED with the QA rejection and its meaning.

Keep the exports, the verifier output and the MES screenshots or extracts together. That is
the PQ record.

## Change control

A change to a type (`types/*.json`), a rule, the checker, the readers or the writer re-runs
the OQ in full. A change to the Server version re-runs the OQ and records the Server version
(`GET /health/ready` reports it) and the image digest the install pinned.
