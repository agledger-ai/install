# Employment / FCRA adverse action: AGLedger vertical recipe

A set of contract types for notarizing an FCRA-compliant employment background-screening flow: an
external consumer reporting agency (CRA) renders the background-check adjudication, a human runs
the EEOC individualized assessment, and, when the outcome is adverse, the recipe drives the FCRA
two-step with a mandatory waiting period: pre-adverse notice, wait, final adverse action. It is a
**starting point you adapt**, not a turnkey product: a working scaffold meant to be imported into
your own Server and reshaped to your screening process and your CRA. ("Ironvale" is a sample
employer; rename the types to whatever you like.)

**The defining property is temporal: the gate is a clock.** FCRA 604(b)(3) requires the employer
to give the candidate a pre-adverse notice (a copy of the actual report plus the CFPB summary of
rights), then wait so the candidate can dispute errors, then take the final action under 615(a).
The elapsed interval is a litigated fact (*Tyus v. U.S. Postal Service*: a 3-day window against a
promised 5 was held actionable; 14 days "ample"). This recipe makes the wait **engine-enforced**
(the wait gate refuses to settle until the committed window has elapsed between two timestamps the
engine itself signed) and the interval **provable offline** from those signed record timestamps.
What is normally a swearing contest becomes a signed fact.

## Why gates here

Two acts are gated by the engine and two by humans:

- **Adjudication routing (engine, auto).** The `ironvale-adjudication-gate-v1` rule settles
  FULFILLED only when the CRA's normalized outcome equals the operator's auto-clear value
  (`pass`); `needs-review` or `fail` settles FAILED and routes the candidate to a human
  individualized assessment. The engine decides review-required from the CRA's rendered outcome.
  This deliberately replaces a self-attested "needs review" boolean that an orchestrator could set
  false to launder an adverse-capable report past human review. The rule is a case-sensitive
  string equality; string verbs carry no widening tolerance, so there is no band to quietly loosen.
- **The waiting period (engine, auto).** The `ironvale-wait-window-gate-v1` rule is an expression
  over signed time: the gate is created as a child of the pre-adverse notice, and it settles
  FULFILLED only when the whole days elapsed between the notice's engine-signed timestamp and the
  gate record's own engine-signed timestamp reach `committedWaitDays`. You supply no datetime, so
  the floor cannot be understated; a gate created without its parent fails closed, and a too-early
  attempt settles FAILED as signed evidence of the refusal. The FCRA clock becomes a preventive
  control, not an after-the-fact dispute.
- **The individualized assessment (human, principal).** An EEOC Title VII control, not an FCRA
  one: a senior reviewer weighs the Green factors (nature of the offense, time elapsed, job
  relatedness) before a candidate is screened out. The reviewer renders the verdict; AGLedger
  holds it with attribution and never renders it. A decision to initiate adverse action with any
  Green factor recorded as not-considered is refused by the schema.
- **The final adverse action (human, principal).** The terminal decision, reachable only through a
  reference to the FULFILLED wait gate. On `decision: adverse` the full FCRA 615(a) disclosure
  block is conditional-required (CRA identity and phone, the CRA-did-not-decide statement, the
  free-report-within-60-days right, the dispute right); a reversed-to-hire outcome needs none of it.

The value AGLedger adds is a signed, hash-chained, offline-verifiable record of *the order placed
under a permissible purpose, the adjudication exactly as the CRA rendered it, that a named human
performed the individualized assessment, that the pre-adverse notice went out with the report copy
and summary of rights, and that the final adverse action came only after the committed wait*,
provable without trusting your ATS's own logs.

## What you get

Seven contract types in `types/`, registered in the order below. Three are notarize-only (they
record what happened and terminalize in one signed call); two are engine gates settled
automatically by a rules-engine comparison; two are principal gates whose human verdict is held
on-chain.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `ironvale-screening-order-v1` | notarize-only | The order to the CRA under an FCRA permissible purpose, with a reference to the retained disclosure-and-authorization artifact. |
| 02 | `ironvale-consumer-report-v1` | notarize-only | The SoR seam: the adjudication as the CRA rendered it (verbatim result label plus a normalized `engineOutcome` enum, and a `reportHash` binding the exact report bytes). |
| 03 | `ironvale-adjudication-gate-v1` | **engine-gate (auto)** | Auto-clear vs human review, decided by the engine from the CRA's normalized outcome. FULFILLED clears to hire; FAILED routes to the individualized assessment. |
| 04 | `ironvale-individualized-assessment-v1` | **principal-gate** | The EEOC Green-factors review by a human. On `initiate-adverse` all three factors are conditional-required true. |
| 05 | `ironvale-pre-adverse-notice-v1` | notarize-only | The FCRA 604(b)(3) notice that starts the clock: report copy and summary of rights are const-true, `committedWaitDays` states the window, and the record's signed timestamp is T0. |
| 06 | `ironvale-wait-window-gate-v1` | **engine-gate (auto)** | The clock: a child of the pre-adverse notice that refuses to settle until the committed wait has elapsed between the notice's and its own engine-signed timestamps (expression rule on signed time). |
| 07 | `ironvale-final-adverse-action-v1` | **principal-gate** | The terminal human decision (adverse or reversed-to-hire), reachable only via the FULFILLED wait gate, with the 615(a) disclosure block conditional-required on adverse. |

## The CRA seam

AGLedger notarizes what the CRA rendered; it never renders the adjudication. The recipe was built
and exercised against **Accurate Background's** developer sandbox (self-serve, instant, free), and
the adverse-action notice types were modeled against **Checkr's** adverse-action API shapes (the
two-stage pre/post split with a selectable wait). The seam carries to any CRA that returns an
order-level disposition.

1. **Order out.** Place the screening order with the CRA, then notarize
   `ironvale-screening-order-v1` with the order id, package, and the reference to the retained
   disclosure and authorization.
2. **Adjudication in.** When the CRA renders its result, notarize `ironvale-consumer-report-v1`
   with the verbatim customer-facing label (labels are client-customizable, so they are free-form)
   plus the normalized `engineOutcome` enum the gate bands on. Mapping label to enum is your
   seam adapter's job, and that mapping is itself on-chain in this record.
3. **Report copy delivery.** The candidate's right to a copy of the actual report rides the
   pre-adverse notice; `reportHash` binds "the report adjudicated" to "the report disclosed".

Make the CRA endpoint and auth env-configurable (base URL, an `Authorization` header, a provider
label) so a production deployment swaps the sandbox for the hosted CRA API without touching the
types.

## Controls in this recipe

- **Engine adjudication gate** (`ironvale-adjudication-gate-v1`, string equality). The engine
  decides review-required from the CRA's rendered outcome, not from a self-attested flag.
- **Engine wait-window gate** (`ironvale-wait-window-gate-v1`, expression on signed time). A
  too-early attempt settles FAILED. Both instants are engine-signed, so the interval is provable
  offline and cannot be supplied dishonestly.
- **Const-true notice contents** (engine, structural). A pre-adverse notice that did not include
  the report copy or the summary of rights is not a valid 604(b)(3) notice; the schema refuses it
  at creation.
- **Conditional-required Green factors** (engine, structural). An `initiate-adverse` assessment
  that records any Green factor as not-considered is refused.
- **Conditional-required 615(a) block** (engine, structural). An adverse decision missing the CRA
  identity, the CRA-did-not-decide statement, or the candidate's rights statements is refused; a
  reversed-to-hire decision carries none of it.
- **Report-bytes binding.** `ironvale-consumer-report-v1.reportHash` is the digest of the exact
  report the CRA produced, so the report adjudicated and the report disclosed to the candidate are
  provably the same document.

## Lessons for implementers

What we learned building and exercising this recipe: the things worth knowing before you adapt it.

### The honesty boundary: what this does, and does not, do

AGLedger is a notary, not a guard. Every order, adjudication, assessment, notice, and decision is
recorded, attributed to a signing identity, hash-chained, and offline-verifiable. AGLedger does
**not** run the background check, judge whether the reviewer's Green-factors reasoning was
adequate, or decide whether the adverse action was justified; the CRA renders the adjudication,
your reviewer renders the assessment, and a regulator or court judges adequacy. The chain proves
*what was decided, by whom, on which report, and when*, and in this vertical the "when" is the
point: the interval between the two signed timestamps is the fact a dispute turns on.

For anything an auditor relies on, read `GET /v1/records/{id}/audit-export` (or pass
`?integrity=true`), not the plain record body; the export offline-verifies against the public key
from `GET /v1/verification-keys`.

### The wait gate reads the clock itself; wire the parent binding

The gate compares two timestamps the engine signed: the pre-adverse notice's and the wait-gate
record's own. You supply no datetime, so an orchestrator cannot understate the floor. (An earlier
form of this recipe compared two supplied datetimes and leaned on an offline cross-check to catch
an early floor; that gap is closed.) The contract:

- **Notarize the pre-adverse notice under the sending agent's key**, not an org-admin key. An
  admin-notarized record has no performer and can never anchor children.
- **Create the wait gate at final-action attempt time** with `parentRecordId` set to the notice
  and `preAdverseRef` echoing the same id; the offline cross-check asserts the echo matches.
- **Only the notice's performer key may create the gate**, and the gate's principal is that same
  identity. To keep the attempt on a distinct authorizer, create it with `performerAgentId` set to
  the authorizer's agent and drive the four-step flow: the notice sender proposes and activates,
  the authorizer accepts and completes.
- **A FAILED early attempt does not consume the notice.** Retry after the window with a new gate
  under the same parent; the refusal stays on-chain as signed evidence that the engine held the
  line.
- **There is no tolerance to police.** Expression rules take no tolerance parameter, so the
  grace-widening footgun the earlier datetime form carried is gone by construction.

One control remains yours: the engine enforces whatever `committedWaitDays` was recorded; it
cannot cross-check that number against your policy. Understating the committed window at notice
time is the residual dodge, so cross-check `committedWaitDays` against your policy floor
operator-side, and let the offline check assert that the notice, the gate, and the final action
all carry the same value.

Offline tooling that recomputes the interval from an exported chain still derives each record's
signed time from its attestation (the CWT `iat` claim, second precision) rather than the record
JSON's millisecond `createdAt`.

### The committed wait is your policy, not the statute

FCRA 604(b)(3) says only that the notice must come "before" the action; it names no number of
days. About 5 business days is common FTC and case-law guidance, and *Tyus* shows a too-short
window against a promised one is actionable. Set `committedWaitDays` to your policy, use the
stricter floor where a state or city overlay applies (California and NYC fair-chance rules, for
example), and never represent a specific day count as an FCRA statutory requirement. The schema
allows `0` for integration wiring only; production deployments must set at least 1.

### Separation of duties lives in your orchestrator, not the type

Three identities should be distinct: the screening orchestrator (performer), the individualized-
assessment reviewer (principal on 04), and the final-action authorizer (principal on 07); bind
keys to named humans through your IdP where you can. The engine enforces that a performer cannot
render the verdict on a record they performed, within a single record; it does not enforce
reviewer-is-not-authorizer across records. Likewise `gateMode` is a record-creation parameter, not
a schema field, so a caller could create the assessment or the final action with `gateMode: auto`
and bypass the human verdict. Your orchestrator owns both rules: route the two human gates through
principal mode always, and provision the three roles as distinct identities. Every verdict is
attributed on-chain, so a self-escalation is catchable; the point is to make it impossible in your
deployment, not merely visible.

### Notice routing: scope the candidate channel server-side

The FCRA notices are required TO the candidate (the mirror of the finance-KYC no-tip-off
inversion), but the flow also produces records the candidate must never see: the individualized
assessment carries the reviewer's privileged reasoning, and the raw consumer-report record carries
the CRA's disposition. Scope the candidate subscription with `recordTypes` (API v1.2.0 and later)
to exactly the two notice types, as `notify.yaml` does, and the Server refuses to deliver anything
else to that endpoint. The physical letter is a separate seam: the recipe notarizes the decision
and the interval, and letter fulfillment is wired to the CRA or a managed service by env.

### Driving the Accurate Background sandbox

The sandbox is drivable end-to-end and free, and a few facts are not in its docs:

- **Enrollment is instant and scriptable**: signup is a plain `POST /api/enroll` (Spring XSRF
  cookie plus `X-XSRF-TOKEN` header), the sandbox Client ID and Secret come back inline in the
  enroll response, and the API works before email verification. Auth is HTTP Basic.
- **Order placement needs full candidate PII**: the order is rejected (`code 103`) unless the
  candidate carries `dateOfBirth` plus a full address block. `jobLocation` is an object
  (`country` / `region` / `region2` for county / `city`), not a string, and `candidateId` is
  accepted on the order body although the published request schema omits it.
- **The deterministic result triggers are undocumented**: the candidate `lastName` drives the
  sandbox result (`PASS` returns "MEETS REQUIREMENTS", `REVIEW` returns "NEEDS REVIEW", plus
  `PENDING` and `CANCELLED`). The go-live docs say only that pre-built test results are returned.
- **Sandbox report bytes are identical across candidates** (one digest for every report), so
  hashing the report document proves nothing there; hash the order id plus the verbatim result in
  sandbox, and hash the real report bytes in production.
- **`GET /package` fails on sandbox accounts**; order directly with the documented package codes
  (`PKG_BASIC` / `PKG_STANDARD` / `PKG_PRO`).
- **`subjectNotification` is sandbox-disabled**, so the CRA-side report-copy delivery leg cannot
  be rehearsed pre-production; the notarized `reportCopyProvided` attestation is the recipe's
  record of it either way.

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
Servers), see the **Define Custom Types** guide. For the Notify subscriptions in `notify.yaml`,
see the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks only to
the `AGLEDGER_API_URL` you give it (your own Server) and makes no outbound calls to any registry,
our website, Docker Hub, or npm. The CRA is a separate system you integrate: the screening leg of
the orchestrator needs egress to the CRA's API (sandbox or production), and AGLedger notarizes
whatever the CRA renders. Everything on the AGLedger side, including offline verification of the
interval, works with no route to the CRA at all.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or delete
any of them. AGLedger ships a deliberately minimal core rather than opinionated built-in types; a
recipe is a head start you own, not a platform-managed type kept in lockstep with your business.
