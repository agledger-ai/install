# Operational and performance qualification

The OQ is a scripted run of both workflows against your own install, with every assertion in
`TRACEABILITY.md` made and logged. `oq/run.sh` is that script for the reference system of
record. A quality team runs it, keeps the bundle it leaves, and files it with the matrix and
the intended-use statement. Nothing here is a certificate; it is the evidence a site's own
validation uses.

## OQ: run it

Prerequisites: a test install with the types registered (`register.sh`), the system of
record up (`sor/setup.sh`; the driver seeds it), an admin key, `jq` for `register.sh`,
Python 3.11+, and the published verifier (`agledger-verify`, the `@agledger/verify` package,
2.1.0 or later) on PATH.

    export AGLEDGER_API_URL=... AGLEDGER_API_KEY=...
    oq/run.sh oq-$(date +%Y%m%d)

It runs five steps and exits non-zero if any fails or any requirement is left uncovered:

| Step | Script | What it does |
|---|---|---|
| Drive | `oq/drive.py` | Provisions one agent per role and the writer's read-only key, drives the nine cases below against the Server and Odoo, and saves the bundle: every record's audit export, the completion bodies, the case manifest and the verification keys. |
| Probe | `oq/probes.py` | Sends the bodies the types and the engine must refuse. No system of record needed. |
| Verify | `oq/verify.py` | Runs `agledger-verify` over every export against the saved keys, refusing keys embedded in an export, then alters one character of one export and confirms it is reported. |
| Cross-check | `oq/crosscheck.py` | Compares the records to each other from the bundle alone, with no call to the Server. |
| Matrix | `validation/build-matrix.py` | Builds `TRACEABILITY.md` in the bundle from the log the other four wrote. |

The driver creates agents, records and one manufacturing order on every run, and the probes
leave refused and failed records behind, so the OQ belongs on a test install.

The four workflow cases, and what is asserted in each:

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
   refuses a payload altered after approval, then re-reads the release and writes the batch
   record; the writer notarizes the receipt; the manufacturing order exists in Odoo with
   the approved lot.
4. **Release D, a failed component lot.** As C on the failed lot. The check settles FAILED,
   the release is held, QA accept is refused, QA reject lands, the writer refuses, and
   nothing was written to Odoo for the proposed lot.

The probes are the refusals the matrix lists: schema conditionals, a release with no named
checker, proposal hash or maximum check age, the list on the check child, the short,
renamed and stale check completions, a comma in a check name, the missing hashes, binding
of duty and circular delegation.

Five more cases are things the engine admits, which the cross-record check has to catch.
The driver runs E to H to the point where QA would be asked to sign, and I through QA's
accept to the writer, which has to refuse. The cross-check passes only if it flags each
with the finding the case exists to raise:

| Case | What the proposer does | Finding |
|---|---|---|
| E | Completes the release with no check child, naming the check of another release | `checkRef` |
| F | Creates the check child without `autoActivate`, cancels it, completes the release | `checkRef` |
| G | Names itself the checker and performs the check | `checker` |
| H | (QA) requests a revision on a release rejected over a failed check | `revision` |
| I | Completes the release after the check has passed the age the release allows (one minute; the run waits 65 seconds) | `age` |

### The cross-record checks

`oq/crosscheck.py` reads the exports, `completions.json` and `case-manifest.json`. Every
completion body it uses has to hash to the `evidenceHash` on the chain. For a complaint
case: the close-out's `evidenceRecordIds` equals the case's children; its
`sorWriteStampDigest` re-derives from the reads' `sourceRecords`; the verdict entry carries a
signature meaning, names the completion it signs, and was rendered by the principal under
its own key. For a release: the completion's `checkRef` is a FULFILLED precondition check
that is a child of the release, settled before the completion was submitted; its performer
is the checker the release names (`checkerAgentId`); the check was no older than
`maxCheckAgeMinutes` at the release completion, at QA's accept and at the receipt; the
release's `proposalHash`, product, lot and quantity equal the proposal record's, and the
check names the same proposal; the child's `controlPlanRef` and `controlPlanHash`, and the
plan as the checker read it, equal the release's; the receipt's `payloadHash` equals the
approved one and was written after the verdict; and no revision was requested over a failed
check. The `checkRef`, `checker`, `plan` and `proposal` checks need only the proposer's
completion, and `age` is measured to whatever has happened so far, so the same script runs
before QA signs.

The script's header gives the bundle format. It is independent of the system of record: a
bundle written by your own orchestration is checked the same way.

### The log and the matrix

Each script appends the assertions that held to `oq.log` in the bundle, one line each as
`<requirement id><TAB><assertion>`, and refuses an assertion that is not a line of
`REQUIREMENTS.json`. The matrix is built from that log:

    python3 validation/build-matrix.py oq-20261116/oq.log oq-20261116/TRACEABILITY.md

A requirement with no assertion is marked UNCOVERED in the table and the build exits
non-zero. Without the second argument the build overwrites the shipped `TRACEABILITY.md`.

## What the OQ does not cover

- The site's own systems. The reference automations drive the Odoo rig in `sor/`, and
  `oq/drive.py` calls them and seeds that rig. A site that replaced `checker.py`,
  `readers.py` and `writer.py` with implementations against its MES, LIMS and ERP changes
  the driver's fixtures (the product, the lots, the control plan reference) to its own and
  re-runs the OQ against those. The probes, the verifier step, the cross-check and the
  matrix build do not touch the system of record and run unchanged.
- Identity binding. The signers in the reference run are API-key agents named for their
  roles. A site binds each to a person (OIDC workload identity, or key custody under its
  SOP); see "Binding a signer to a person" in the README.
- Retention and availability of the ledger (vault checkpoints, anchors, backups): the
  Server's operations runbook, not this recipe.

## PQ: run it as the site runs it

Performance qualification is the OQ's scenarios driven with the site's identities, data
and systems on the production-shaped install, under the SOP that will govern it:

1. Open one real complaint case with the QA investigator's own credential; let the site's
   readers attach their evidence; close it. Export the case and its children, save the
   completion bodies and a case manifest beside them, verify the exports (`oq/verify.py`)
   and run the cross-record checks (`oq/crosscheck.py`).
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
