# Pharma GxP (complaint investigation and batch record release): AGLedger vertical recipe

Two quality workflows from a GMP manufacturing site, recorded on an AGLedger Server so that
an inspector can read who proposed, who checked, what the systems answered, who signed and
with what meaning, and verify all of it offline against published keys:

1. **Complaint investigation, read-only.** A named QA investigator opens a case; automations
   read the manufacturing, laboratory, distribution and complaint-history datasets and attach
   what they found as hash-bound evidence under the case, each under its own identity; the
   investigator closes the case with a signature that carries its meaning. No system of
   record is written, and the ledger can show it.
2. **Batch record release.** An automation (an LLM-driven agent, if you choose) proposes a
   batch; a named QA person opens the release from the product's control plan; a
   deterministic checker runs the required checks against the systems; the release cannot be
   completed before the check settles or after it fails; QA approves with a Part 11
   signature meaning; the writer creates the batch record from the approved payload and
   notarizes the system of record's receipt with the same hash.

It is a **starting point you adapt**, not a turnkey product: six contract types, three
reference automations against a self-hosted Odoo, a scripted OQ with a cross-record checker,
and a validation package (intended use, requirements, a traceability matrix, OQ and PQ
guidance).

**Why this shape.** The draft EU GMP Annex 22 (published for consultation in July 2025,
unadopted as of October 2026) keeps generative and large language models out of critical GMP
applications and allows them elsewhere only under human review. FDA's warning letter to
Purolea Cosmetics Lab (2 April 2026,
https://www.fda.gov/inspections-compliance-enforcement-and-criminal-investigations/warning-letters/purolea-cosmetics-lab-722591-04022026)
cited 21 CFR 211.22(c) over specifications, procedures
and master production or control records that AI agents had created without the quality
unit's review. MHRA's inspectorate wrote on 29 June 2026
(https://mhrainspectorate.blog.gov.uk/2026/06/29/use-of-ai-for-gxp-inspection-responses-setting-standards-without-stifling-innovation/)
that AI-assisted submissions must be signed off by someone with authority and accountability. So the LLM in this recipe only
proposes. The critical steps are a deterministic check whose reads are hash-bound to the
systems, and a human signature with a meaning, and the engine orders them: no release
completion until the check settled, none after it failed.

**Built against Odoo 18.0 Community with the OCA `manufacture` quality modules** as the
manufacturing, inventory and quality system of record (`sor/`), on an AGLedger 2.2.0 Compose
install. A site replaces the three reference automations with its own against its MES, LIMS
and ERP and keeps the evidence shapes the types declare.

## Contract types

| Type | Gate | Who creates | Who completes | What it records |
|---|---|---|---|---|
| `calder-complaint-case-v1` | principal (QA investigator) | QA investigator, naming the orchestrator | orchestrator, after every read is terminal | the complaint as received (hashes, lots, category, distributed), `readOnly` const true; close-out with the 211.198 decisions and the write-stamp digest |
| `calder-evidence-read-v1` | auto: read-only invariant | orchestrator (parent performer), as a child | the reader automation itself | query hash, result hash, source records with the system's own write stamps, `mutating` |
| `calder-batch-record-proposal-v1` | notarize-only | the proposer | n/a | product, BOM, lot, component lots, line, `producedBy` (llm, rule-based or human), rationale as a claim |
| `calder-batch-record-release-v1` | principal (QA release) | QA release, naming the proposer | proposer, after the check child settled | `requiredChecks` and `controlPlanHash` from the quality system, the proposal's hash, the checker QA expects and the maximum age of the check; completion names the check and binds the payload hash; the verdict is the signature |
| `calder-precondition-check-v1` | auto: all required checks passed | proposer (parent performer), as a child | the checker automation | every check with source record, observed, expected, passed; the control plan as re-read |
| `calder-sor-write-receipt-v1` | notarize-only | the writer | n/a | model, id, name, lot, the system's write stamp, payload hash equal to the approved one |

## What you get

- `types/`: the six contract-type registration bodies, in registration order.
- `register.sh`: POSTs them to your Server (an admin key with `schemas:write`).
- `notify.yaml`: the three webhook subscriptions the recipe expects (the QA queue, the
  automation gates, the batch record channel), each scoped server-side with `recordTypes`.
- `sor/`: the reference system of record and the reference automations: `setup.sh` and
  `docker-compose.yml` stand up Odoo; `seed-sor.py` creates the fixtures; `checker.py` is the
  deterministic precondition checker; `readers.py` are the four dataset readers;
  `writer.py` builds the batch record payload and writes it after approval; `odoo.py` is the
  standard-library JSON-RPC client they share, which counts reads and writes.
- `oq/`: the scripted OQ. `run.sh` runs it end to end: `drive.py` drives both workflows and
  five cases the engine admits, `probes.py` sends the bodies that must be refused,
  `verify.py` runs the published verifier over every export, and `crosscheck.py` compares
  the records to each other from the exports alone. Standard-library Python.
- `validation/`: `INTENDED-USE.md`, `REQUIREMENTS.json` (nineteen requirements, each with the
  type or engine rule that satisfies it and what an OQ asserts), `TRACEABILITY.md` built from
  it, and `OQ-PQ.md`.

## Controls in this recipe

- **Read-only invariant** (`calder-evidence-read-v1`, expression rule). Settles FULFILLED only
  when `mutating == false`, the source system equals the one declared at create, and the
  record count equals the records listed. `mutating` is computed by the reference reader from
  its client's write counter, not asserted. A FAILED read fails the case by rollup, so a
  complaint investigation that wrote to a system of record cannot close as read-only.
- **All required checks passed** (`calder-precondition-check-v1`, expression rule). Settles
  FULFILLED only when the plan names at least one check, `failedChecks` is empty,
  `passedChecks` equals the plan's list as the checker read it (same names, same order, same
  count), and the re-read `controlPlanHash` equals the one on the check record's criteria.
  One failed check, a short passed list, a renamed check and a stale plan all settle FAILED.
  The child carries no list of checks, only the plan hash. Check names are lower-case
  letters, digits and hyphens on both types: the engine compares the two lists as joined
  strings, so a comma in a name is refused by pattern.
- **Ordering, by the engine's cascade settlement.** While a check child is open, the
  release's own completion is refused (422 `has_children_leaf_only`), and the case's while
  any read is open. A failed one-shot child rolls up: the parent is held on an
  engine-synthesized completion that takes only a reject verdict, and `accept` is refused
  422. The engine does not require the child to exist, and it never reads the release
  completion's `checkRef`: a proposer that creates no check child, or creates one without
  `autoActivate` and cancels it before it is activated, can complete the release on its own.
  (A child cancelled after activation fails the release by rollup, as a failed check does.)
  Ordering is deny-on-failure, not required-before. QA's review, or the cross-record check
  (`oq/crosscheck.py`), confirms that `checkRef` names a FULFILLED child of this release
  before QA signs.
- **Reject is recoverable.** QA's reject lands the release or the case at FAILED, which is
  not terminal: the principal or an org admin can request a revision, and from there the
  proposer's own completion is graded again. A check that failed stays failed, but a
  release rejected over it can be reopened. Your SOP decides whether a revision is ever
  allowed on a check-failed release; the chain shows it if one was.
- **Binding of duty and no circular delegation** (engine). Only the parent's performer may
  create a child; naming the parent's principal (QA) as a child's performer is refused. The
  engine admits the performer's own id as the child's performer, so a proposer can name
  itself the checker. The release's criteria name the checker QA expects
  (`checkerAgentId`); the engine does not compare it to the check child's performer, so QA
  or the cross-record check does before signing, and the writer does before writing.
- **The proposal, the check's age and the write** (criteria, the cross-record check and the
  writer). The release's criteria carry the proposal's hash (`proposalHash`) and how old
  the check may be when it is relied on (`maxCheckAgeMinutes`). The engine reads neither.
  The cross-record check compares the release to the proposal record and the check's age
  to the limit at the release completion, at QA's accept and at the receipt. `sor/writer.py`
  re-reads the release from the ledger before it writes and refuses unless the release
  reads FULFILLED on an accept verdict, its completion binds the payload's hash, the check
  is a FULFILLED child performed by the named checker, and the check is within the limit.
- **Structural claims** (schema). `readOnly` const true on the case; `checkOutcome` const
  FULFILLED on the release completion; `checkerKind` const deterministic; sha256 patterns on
  every hash; UUID patterns on every record reference; conditionals for CAPA, reportability,
  and, when no investigation was performed, a written reason and the name of the
  responsible person who decided (`noInvestigationDecidedBy`, 211.198(b)(3)); `model`
  required when `producedBy.kind` is `llm`.
- **Signature meaning on the chain.** The QA verdict's `checks` object (signatureMeaning,
  signerName, signerRole, regulation, signedAt) is preserved verbatim on the signed
  OUTCOME_REPORTED entry of the audit export, linked to the completion it signs. The
  `checks` object is caller-supplied text the engine stores, not validates, and an org-admin
  key can render the verdict for the principal; the entry names the reporter, so the OQ
  asserts the reporter is the principal's identity.

## Lessons for implementers

The things worth knowing before you adapt it.

### One submission and a deadline on every gated child

A FAILED record is revisable until its deadline passes or its submission budget is spent, and
a revisable failure is not terminal to the cascade: the parent waits on it. Create every
evidence read and every precondition check with `maxSubmissions: 1` and a `deadline`, so a
failed read or a failed check is final and fails the parent at once. Without them the parent
sits ACTIVE reading `awaitingActor: performer`, in the performer's `?actionable=true` listing,
because the failed child's principal is the parent's performer and can still send the child back
for rework; the parent does not fail until that child's deadline passes or its budget is spent. Your org must run
`enforcement.maxSubmissionsMode: enforced` (the default) for the cap to count. The served
guide says the same in the first bullet of its "Cascade settlement" section; read that bullet
before designing any one-shot check as a child.

### The gate and the roles are recipe-enforced, not type-enforced

`gateMode` is a record-creation parameter, so a caller could open the case or the release
with `gateMode: auto`; the orchestration must not. The engine does not refuse
`principal == performer` on the release, so provisioning must keep the QA signer, the
proposer, the checker and the writer as distinct identities. The engine does refuse the two
delegation shortcuts that would collapse the roles (binding of duty, circular delegation).

### The child carries the plan hash, never the list

The release's `requiredChecks` are QA's record of the control plan. The check child, which the
proposer must create (only the parent's performer may delegate), carries the plan's hash and
a pointer to it (`controlPlanRef`), never the list, and the checker reads the plan from the
quality system itself and hashes it. So a proposer has nothing to shorten: a child with a list
is refused at create, and a hash that is not the hash of the plan the checker read fails the
check.

The engine compares the checker's re-read hash to the hash on the child's own criteria. It
cannot see the release from inside the child, so a proposer who points `controlPlanRef` at a
shorter plan and copies that plan's hash gets a check that settles. Two things close that:
the checker reads its plan reference from the release record, not from the child, and the
cross-record check below compares the child's `controlPlanRef` and `controlPlanHash` to the
release's.

The rule the design follows: a control an LLM carries from one record into the next is a
control it may edit, so put the control where no LLM carries it. The measurement behind that
rule is at https://agledger.ai/blog/six-llms-batch-record-control-plan/.

The one lie left is a checker that reads a shorter plan than the quality system holds. The
engine cannot see that from inside one record. Compare, across the audit exports: that
the release completion's `checkRef` is a FULFILLED child of the release whose performer is
the expected checker; the checker's plan list to the release's `requiredChecks`; and the
child's `controlPlanRef` and `controlPlanHash` to the release's. `oq/crosscheck.py` makes
those comparisons. A short list sits on the checker's signed completion under the checker's own identity, attributed
and catchable against the quality system's own plan. Keep the checker's plan source the
quality system, and keep the checker deterministic code.

### What `mutating: false` proves

The reference reader counts its own write calls; a reader that lies can write `false`. The
stamps make the lie catchable: every read lists the source records with the system's own
`write_date`, the close-out binds a digest over those stamps as re-read at close, and a
cross-record check re-derives it. A write between read and close moves a stamp; a write by
the reader itself moves the stamp of what it wrote. An auditor with access to the system of
record compares the stamps on the chain to the system's audit log. The ledger proves what
was read and when; the system's own log proves what was written.

### Binding a signer to a person

The signers in the reference run are API-key agents named for their roles. 21 CFR 11.100
wants the signature to belong to one individual. Bind the QA credentials through OIDC
workload identity (the chain entry then carries `actorOidcSub`; the insurance recipe's
`oidc/` directory shows the pattern) or through key custody under your SOP.

### What the ledger evidences, and what stays with your systems

The ledger records who proposed, who checked, what the systems answered, who signed and with
what meaning. It does not judge the complaint, the batch or the inspection results: the
checker reads what the quality system says, and a wrong control plan passes a wrong check.
The proposal is notarized as the proposer's claim; the checker and QA decide. `checkerKind`
is a structural claim, and the validation package is where a site shows what the checker is.
The read-only guarantee is on the ledger side: the reads are gated and the stamps are bound,
and whether anything else wrote to the system in the window is the system's own log.

### Working with the engine and the exports

- **A parent that is not ACTIVE takes no children.** In a scripted OQ, create every child
  before any of them completes, or the first failure rolls the parent out of ACTIVE and the
  rest are refused 400 for a reason that has nothing to do with the probe.
- **The export carries evidence hashes, not evidence.** A cross-record check needs the
  completion bodies from somewhere; save them beside the exports when you run the workflow.
  `oq/drive.py` saves them as `completions.json`, and `oq/crosscheck.py` holds each body it
  reads to the `evidenceHash` on the chain (SHA-256 over the RFC 8785 canonical JSON of the
  body), so an edited body is reported, not compared.
  The engine-synthesized rollup completion, by contrast, is on the chain in full on the
  GATE_HELD entry.
- **A cancel means two things.** A child cancelled before it is activated is neutral to its
  parent; a child cancelled after fails the parent by rollup. Both read `CANCELLED` on the
  record, and the export's state-change entry says which (`CANCELLED_PRE_WORK`,
  `CANCELLED_IN_PROGRESS`).
- **`structuralValidation` is `ACCEPTED`, `INVALID` or `WARNING`.** Branch on `INVALID`, as
  the Server's `/llms.txt` says; do not expect `VALID`.
- **An `INVALID` completion spends a submission.** On a one-shot child (`maxSubmissions: 1`)
  a body the schema refuses uses the only submission and leaves the child ACTIVE: its next
  completion is refused 422, and the parent's own completion is refused while the child is
  open. Cancelling the child fails the parent by rollup. Validate the checker's and the readers'
  bodies against the type's `completionSchema` before they submit.
- **The writer needs a read credential.** An agent key reads only the records it is a party
  to, and the writer is a party to no release. Give it a read-only key beside its agent
  key: an admin key minted with `scopeProfile: admin-observer` reads records, completions
  and audit exports and is refused every action.

### Working with Odoo

- **OCA quality test questions need a value set and a unit.** A qualitative question needs
  `ql_values`; a quantitative one needs a `uom_id`, and an inspection line created from a
  test without one cannot be confirmed until a unit is written on the line. An inspection
  created bare has no lines and reads `success` vacuously; populate it through the
  `qc.inspection.set.test` wizard. `seed-sor.py` does both.
- **Line clearance reads open orders, so fixture hygiene matters.** A half-finished order from
  an earlier run fails `line-clear` for every later proposal; the seeder cancels strays.
- **Odoo 18.0, not 19.0.** On the 19.0 OCA branch only `quality_control_oca` exists; the stock
  and MRP quality modules this recipe reads are 18.0.

## The system of record

`sor/setup.sh` stands up Odoo 18.0 Community with the OCA `manufacture` addons
(`quality_control_oca`, `quality_control_stock_oca`, `quality_control_mrp_oca`) on
`127.0.0.1:18069`, pinned to an OCA commit (`setup.sh` stops if it cannot check that commit
out). `sor/seed-sor.py` creates the fixtures: a
lot-tracked intermediate and solvent, a BOM, two solvent lots with incoming inspections (one
passed, one failed), the control plan as a `qc.test` whose questions are the check names, a
release assay test on the production-done trigger, and one finished historic batch
(`BATCH-2026-0917`) with its release inspection confirmed. It prints the Odoo ids as JSON
(`controlPlan`, `bom` and the rest); prefix them as `qc.test/<id>` for the checker's
`control_plan_ref` and `mrp.bom/<id>` for the proposal's `bomRef`.

- `sor/odoo.py`: a standard-library JSON-RPC client that counts reads and writes and keeps
  the last request and response bytes. The readers hash the canonical JSON of the records
  they assemble and a canonical description of the query, not those raw bytes; hash the raw
  bytes instead if your auditors want to replay the query.
- `sor/checker.py`: the deterministic checker. `run(odoo, proposal, control_plan_ref)` reads
  the control plan, runs each named check (`bom-active`, `component-lots-on-hand`,
  `component-lots-inspected`, `line-clear`, `lot-number-unique`), refuses to sign if it
  issued a write, and returns the completion evidence for `calder-precondition-check-v1`. A
  check the plan names that the checker does not implement is reported failed, never
  skipped. `component-lots-on-hand` takes what is needed from the BOM, never from the
  proposal: every BOM component has to be covered by proposed lots that together hold the
  BOM quantity, and a proposed lot of a product the BOM does not list fails the check.
- `sor/readers.py`: the four readers (MES, LIMS, distribution, complaint history on the
  ledger). Each returns query hash, result hash, stamps and a bounded summary as the
  completion evidence for `calder-evidence-read-v1`. The complaint-history reader searches
  the ledger through a callable you supply; an agent key's search is scoped to that agent's
  own records, so give it an admin-key search, and treat an empty history as a result to
  check, not a pass.
- `sor/writer.py`: `build_payload` so the proposer can hash the batch record before approval,
  and `write` which, after approval, re-reads the release through a ledger read you supply
  (`authorize`), raises `Refused` with nothing written if the release does not authorize
  the write, and otherwise creates the lot and the manufacturing order from exactly that
  payload and returns the criteria for `calder-sor-write-receipt-v1`.

Odoo is a third-party system you run inside your own perimeter, so the recipe needs no
vendor sandbox. A proposal for the checker and the writer is a plain object (`line` is
required by the proposal type and is not read by the reference checker or writer):

```json
{
  "productCode": "API-INTERMEDIATE-7",
  "bomRef": "mrp.bom/<id>",
  "quantity": 10,
  "proposedLot": "BATCH-2026-1044",
  "componentLots": [{ "productCode": "SOLVENT-A", "lotName": "SOLV-2026-0142", "quantity": 20 }],
  "line": "LINE-3"
}
```

## Install

You administer your own Server, so registering these types *is* the install: no external registry,
no shared signing infrastructure.

```bash
export AGLEDGER_API_URL=https://agledger.internal.example
export AGLEDGER_API_KEY=agl_adm_...   # an admin key with schemas:write; register.sh refuses a platform key
./register.sh
```

`register.sh` POSTs each type to `POST /v1/schemas` in order and prints what landed. Re-running
registers a new version of any type whose schema changed compatibly, and a type whose file is
unchanged answers 200 with its current version and registers nothing; an incompatible change is
rejected and reported. See `register.sh` for the `RECIPE_FORCE=1` reset option (destructive;
scratch orgs only).

To stand up the reference system of record:

```bash
sor/setup.sh && python3 sor/seed-sor.py > seed.json
```

To run the OQ against the two (a test install: it creates agents, records and one
manufacturing order per run):

```bash
oq/run.sh        # needs agledger-verify on PATH; see validation/OQ-PQ.md
```

For the per-call mechanics (preview, compatibility modes, versioning, and sharing types across
Servers), see the **Define Custom Types** guide. For the Notify subscriptions in `notify.yaml`, see
the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks only to
the `AGLEDGER_API_URL` you give it (your own Server) and makes no outbound calls to any registry,
our website, Docker Hub, or npm. The reference system of record under `sor/` is a separate system: `setup.sh` clones the OCA
`manufacture` repository and `docker compose` pulls the `odoo:18.0` and `postgres:16` images, so
stage those inside the perimeter first or point the automations at your own MES, LIMS and ERP. Everything on the
AGLedger side, including offline verification of the exports, works with no route to Odoo at all.
`oq/verify.py` runs `agledger-verify`, the `@agledger/verify` package, which you stage the same way;
the rest of `oq/` is standard-library Python.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or delete
any of them. AGLedger ships a deliberately minimal core rather than opinionated built-in types; a
recipe is a head start you own, not a platform-managed type kept in lockstep with your business.
Replace `checker.py`, `readers.py` and `writer.py` with implementations against your own systems,
keep the evidence shapes, and re-run your OQ (`oq/run.sh`, `validation/OQ-PQ.md`).
