# HMRC MTD VAT (statutory filing): AGLedger vertical recipe

A set of contract types for notarizing a UK VAT return filed to **HMRC** under **Making Tax
Digital**: the open obligation as HMRC states it, the nine-box return your software prepared, an
engine pre-flight well-formedness gate, the responsible officer's "true and complete" statutory
declaration held before the irreversible submission, and HMRC's returned receipt or typed rejection
bound to the exact bytes filed. It is a **starting point you adapt**, not a turnkey product: a
working scaffold meant to be imported into your own Server and reshaped to your filing process and
your tax software.

**The System of Record is a government tax authority.** A VAT filing is a statutory act: the
software POSTs the return under a legal declaration (`finalised: true`, HMRC's wording: the
information is true and complete, and a false declaration can result in prosecution), HMRC renders
a binding acceptance (a 12-digit `formBundleNumber` plus `processingDate`) or a typed rejection,
and the filing is irreversible (no amend, no delete; a re-file of the same period is refused
`DUPLICATE_SUBMISSION`; corrections go on a later return). Two things make this vertical
structurally distinct from the other recipes: the bound receipt is the legally-operative artifact
(the taxpayer's proof of having filed, and of when, in a penalty dispute), and the human gate is a
statutory personal declaration, not a business "approve this action".

## Why gates here

Two acts are gated, one by the engine and one by a human:

- **Pre-flight well-formedness (engine, auto).** Before the irreversible one-shot fires, the
  `vat-return-validation-gate-v1` engine rule settles FULFILLED only if the derived-box arithmetic
  is internally consistent (Box 3 = Box 1 + Box 2, Box 5 = |Box 3 - Box 4|, to 2dp) AND the
  submitted `periodKey` matches the obligation retrieved from HMRC. This catches a malformed or
  mis-perioded return before it burns the single submission. It is a client-side structural guard,
  not HMRC's adjudication; HMRC independently enforces the same arithmetic and everything else on
  acceptance.
- **The statutory declaration (human, principal).** Filing under `finalised: true` is a legal
  declaration that the return is true and complete. The `vat-return-declaration-v1` principal gate
  holds that declaration: the preparer (performer) submits the return for declaration; a distinct
  responsible officer, director, or authorised agent (principal) renders accept via
  `POST /v1/records/{id}/verdict`. That signed acceptance *is* the declaration, made before the
  irreversible `POST /organisations/vat/{vrn}/returns`.

The value AGLedger adds is a signed, hash-chained, offline-verifiable record of *the obligation
HMRC stated, the exact figures declared and from which ledger, that a distinct named officer
declared them true and complete before filing, the exact bytes HMRC received, and HMRC's returned
receipt or typed rejection*, provable without trusting your software's own logs.

## What you get

Six contract types in `types/`, registered in the order below. Four are notarize-only (they record
what happened and terminalize in one signed call); one is an engine gate settled automatically by
an expression rule; one is a principal-gate whose human verdict is held on-chain.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `vat-obligation-retrieved-v1` | notarize-only | The open obligation as HMRC states it (`periodKey`, `dueDate`): the SoR's word on what is due and by when. The root the filing references. |
| 02 | `vat-return-prepared-v1` | notarize-only | The computed nine boxes plus `sourceLedgerHash` (the MTD digital-journey link) and `basis`. The preparer's work product. |
| 03 | `vat-return-validation-gate-v1` | **engine-gate (auto)** | Pre-flight well-formedness: derived-box arithmetic plus periodKey-vs-obligation correlation, via an `expression` field-mapping. FULFILLED means structurally safe to fire the irreversible POST, not a prediction that HMRC will accept. |
| 04 | `vat-return-declaration-v1` | **principal-gate** | The hero human gate: the officer's `finalised: true` legal declaration before the irreversible submission. |
| 05 | `vat-filing-receipt-v1` | notarize-only | The seam: `submittedReturnHash` binds the exact nine-box body; `formBundleNumber` plus `processingDate` (accepted) or `rejectionCode` (rejected) bind HMRC's verdict. |
| 06 | `vat-penalty-observation-v1` | notarize-only | HMRC's out-of-band late-submission or penalty verdict from the penalties API: the SoR's timeliness word. |

## The HMRC seam

Three points connect this recipe to the tax authority. The recipe was built and exercised against
HMRC's MTD VAT sandbox; the shape carries to any statutory-filing SoR that returns a binding
receipt.

1. **Obligation in.** `GET /organisations/vat/{vrn}/obligations` → notarize
   `vat-obligation-retrieved-v1`. Every downstream record correlates to this `periodKey`.
2. **On the FULFILLED declaration.** Fire the one-shot: `POST /organisations/vat/{vrn}/returns`
   with `finalised: true`, only after the officer's verdict lands.
3. **Receipt in.** Whatever HMRC returns → notarize `vat-filing-receipt-v1`: a 201 with
   `formBundleNumber` and `processingDate`, or a typed rejection (`rejectionCode`,
   `rejectionMessage`). Penalty decisions arrive out-of-band via the penalties API → notarize
   `vat-penalty-observation-v1`.

## Controls in this recipe

- **Engine pre-flight gate** (`vat-return-validation-gate-v1`, `expression` rule). Arithmetic
  consistency plus periodKey correlation, settled by the engine. This is derived-field consistency
  plus a cross-record correlation, not a dodgeable self-attested boolean. It does not replace
  HMRC's adjudication.
- **Human gate on the statutory declaration.** `vat-return-declaration-v1` declares
  `defaultGateMode: principal`; a responsible officer renders accept/reject via
  `POST /v1/records/{id}/verdict`. The preparer is a different identity (separation of duties).
- **`finalised` const true** on the declaration completion (engine, structural). A declaration
  record can never carry `finalised: false`: the on-chain declaration always bears the legal
  attestation. (Its *truthfulness* is self-attested; see the honesty boundary.)
- **Conditional-required receipt fields** (engine, structural). `submissionStatus: accepted`
  requires `formBundleNumber` plus `processingDate`; `rejected` requires `rejectionCode` plus
  `rejectionMessage`. A receipt missing them is rejected at creation.
- **Filing-bytes binding.** `vat-filing-receipt-v1.submittedReturnHash` is the sha256 of the exact
  canonicalized nine-box JSON POSTed to HMRC. An auditor recomputes it over the filed bytes;
  `formBundleNumber` is HMRC's proof the government received exactly that.

## Lessons for implementers

What we learned building and exercising this recipe: the things worth knowing before you adapt it.

### The honesty boundary: what this does, and does not, do

AGLedger is a notary, not a guard. Every obligation, prepared return, declaration, and receipt is
recorded, attributed to a signing identity, hash-chained, and offline-verifiable. AGLedger does
**not** compute the tax, verify the figures against the business's reality, or adjudicate
acceptance; HMRC is the sole authority on all three. The box figures are **self-attested**: an
orchestrator that understates a box produces a well-formed, engine-passing, but false return. The
recipe makes that act attributed and tamper-evident, and binds the government's legally-operative
receipt to the exact bytes filed; it does not prevent the lie. If your deployment holds an
independent, separately-notarized ledger extract, cross-check the declared boxes against it as a
periodic audit; absent that, you own the detective half. The chain proves *what was declared, by
whom, over which ledger hash*, and an auditor judges truthfulness.

For anything an auditor relies on, read `GET /v1/records/{id}/audit-export` (or pass
`?integrity=true`), not the plain record body; the export offline-verifies against the public key
from `GET /v1/verification-keys`.

### The pre-flight gate is a structural guard, not HMRC's verdict

The engine arithmetic/periodKey gate exists so a malformed return is caught before the
irreversible one-shot fires. It is not an authority on acceptance: HMRC independently enforces the
same arithmetic (`VAT_TOTAL_VALUE` / `VAT_NET_VALUE`) and everything else, and its verdict is what
the recipe holds (in `vat-filing-receipt-v1`), never recomputes. Do not present the gate as
"AGLedger validated the return to HMRC"; it validated the submission's structural well-formedness.

One mechanical lesson inside the rule: do 2dp money arithmetic with a rounded-difference tolerance
(`abs(a - b) < 0.005`), not `==`, so the float representation of pounds-and-pence does not produce
spurious failures on well-formed returns (repayment, nil, and fractional-pence cases included).

### Driving HMRC: OAuth, sandbox, and fraud-prevention headers

The MTD VAT sandbox is drivable end-to-end, and the OAuth plus fraud-prevention headers are the
only real integration cost.

- **Bootstrap.** Register a free application at `developer.service.hmrc.gov.uk` (client id and
  secret), subscribe it to **VAT (MTD) 1.0** and **Create Test User 1.0**, and add a redirect URI.
  Mint an MTD VAT test organisation, then drive the standard OAuth authorization-code flow to a
  user token with `read:vat write:vat` scope. The sandbox exposes a non-JS sign-in page, so the
  whole journey is scriptable; production is an interactive Government Gateway login.
- **Refresh tokens** make the integration re-runnable without a fresh login; store the
  `refresh_token` and refresh the access token on each run.
- **Fraud-prevention headers** are required on submit. A minimal
  `Gov-Client-Connection-Method: OTHER_DIRECT` plus `Gov-Vendor-*` set is accepted in the sandbox;
  production requires the full `BATCH_PROCESS_DIRECT` set, validated by HMRC's Test Fraud
  Prevention Headers API before go-live.
- **Handle the typed rejection classes.** `DUPLICATE_SUBMISSION` is the natural irreversibility
  guard (a re-file of an already-filed period is refused; notarize it as a rejected receipt, do not
  retry). `TAX_PERIOD_NOT_ENDED` and `VRN_INVALID` are the common pre-flight mistakes. HMRC itself
  rejects `finalised: false`, so there is no un-declared filing path to fall back to.

### Bind the exact bytes you POST

`submittedReturnHash` only means something if the hashed bytes are byte-identical to the nine-box
body HMRC received. Build the return body once into a file, hash that file, and POST that same
file; do not re-serialize between hashing and sending.

### Chain the lifecycle through reference fields, not delegation

The records link through explicit reference fields (`obligationRef` → `preparedRef` →
`validationGateRef` → `declarationRef`) while the org hash-chain binds everything. Do **not** reach
for `parentRecordId` delegation to chain them; delegation would put the whole filing under a single
identity, which defeats the separation of duties between the preparer and the declaring officer.

### The gate and separation of duties live in your orchestrator, not the type

`gateMode` is a record-creation parameter, not a schema field, so a contract type cannot stop a
caller from creating the declaration with `gateMode: auto` and bypassing the human verdict.
Likewise the engine only blocks a performer from rendering the verdict on a record they performed;
it does not reject a record where a single identity is both principal and performer, so a
self-declaration is not refused. So your orchestrator must own the policy:

- route every filing's declaration through the principal gate, and never set `gateMode: auto` on
  `vat-return-declaration-v1`;
- provision the declaring officer as an identity distinct from the preparer (and, for an
  agent-firm filing, the authorising client officer distinct from the agent).

### Keep type descriptions short if you will distribute

`POST /v1/schemas` (register) accepts a long `description`, but `POST /v1/schemas/import` (the
manifest / distribution form) rejects descriptions over 2000 characters. Put long-form deployment
guidance in this README, not in the schema `description`.

## Install

You administer your own Server, so registering these types *is* the install: no external registry,
no shared signing infrastructure.

```bash
export AGLEDGER_API_URL=https://agledger.internal.example
export AGLEDGER_API_KEY=agl_...   # an admin/platform key with schemas:write
./register.sh
```

`register.sh` POSTs each type to `POST /v1/schemas` in order and prints what landed. Re-running
registers a new version of any type whose schema changed compatibly; an incompatible change is
rejected and reported. See `register.sh` for the `RECIPE_FORCE=1` reset option (destructive;
scratch orgs only).

For the per-call mechanics (preview, compatibility modes, versioning, and sharing types across
Servers), see the **Define Custom Types** guide. For the Notify subscriptions in `notify.yaml`, see
the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks only to
the `AGLEDGER_API_URL` you give it (your own Server) and makes no outbound calls to any registry,
our website, Docker Hub, or npm. HMRC is a separate system you integrate: the filing leg of the
orchestrator needs egress to HMRC's MTD API (sandbox or production), and AGLedger notarizes
whatever HMRC states and returns. Everything on the AGLedger side, including offline verification
of the receipts, works with no route to HMRC at all.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or delete
any of them. AGLedger ships a deliberately minimal core rather than opinionated built-in types; a
recipe is a head start you own, not a platform-managed type kept in lockstep with your business.
