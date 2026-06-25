# Finance / KYC adverse action — AGLedger vertical recipe

A set of contract types for notarizing an automated KYC/AML onboarding-screening
pipeline on AGLedger, plus the Notify subscriptions it expects. It is a **starting
point you adapt**, not a turnkey product — a working scaffold meant to be imported
into your own Server and reshaped to your institution's process and systems of
record. The deep model is **KYC/sanctions onboarding adverse action** (an external
screening engine renders the disposition; humans hold the verdict); types 07–10 are
the **credit-ECOA mirror**, the same shape inverted so the notice flows to the
applicant. ("Keystone" is a sample bank; rename the types to whatever you like.)

**What AGLedger does here:** it records each step's intent and outcome — attributed,
hash-chained, and tamper-evident — with an engine verdict (the score band) or a human
verdict (the analyst or officer). AGLedger notarizes what the screening engine
returned and holds the analyst's and officer's verdicts; the screening engine and the
principals are the deciders. It does not decide whether a name is *really* a sanctions
match or whether a customer *should* be onboarded — it is a notary, not the screening
engine and not the compliance officer.

This recipe was built and exercised against OpenSanctions — a production OFAC / EU /
UN / PEP screening engine (yente) — driving real screening matches, so the gate
hand-off matches real sanctions dispositions and the no-tip-off notice obligations.

## What you get

Ten contract types in `types/`, registered in the order below. Six are notarize-only
(they record what happened and terminalize in one signed call); one is an
engine-decided auto-gate; three are principal-gates whose human verdict is held
on-chain.

### KYC / sanctions onboarding (01–06)

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `keystone-onboarding-case-v1` | notarize-only | CDD/CIP case binding; the root every step references by `caseId`. `riskRating` selects the diligence band (SDD / CDD / EDD); optional `beneficialOwnerOf` for UBO sub-cases. |
| 02 | `keystone-sanctions-screen-v1` | notarize-only | The screening-engine seam: notarize the external engine's rendered disposition (`topScore` / `match` / `datasetVersion` / `topMatchDatasets` / `explanationsDigest`). |
| 03 | `keystone-screening-gate-v1` | **auto-gate** | The **engine** bands the score: FULFILLED below the clear threshold (auto-clear), FAILED above it (route to a human). |
| 04 | `keystone-alert-disposition-v1` | **principal-gate** | L1 analyst verdict on the hit (`trueMatch` / `falsePositive` + rationale + list version); entered only after the gate FAILED. |
| 05 | `keystone-onboarding-decision-v1` | **principal-gate** | L2 / MLRO business verdict (`onboard` / `decline` / `exit` / `block`); carries the no-tip-off consistency rule. |
| 06 | `keystone-regulatory-report-v1` | notarize-only | The inverted notice: SAR to FinCEN / blocking report to OFAC, routed to the regulator and withheld from the subject. |

### Credit-ECOA mirror (07–10)

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 07 | `keystone-credit-application-v1` | notarize-only | Loan application; the creditor of record (the ECOA notice obligation) is bound here. |
| 08 | `keystone-credit-decision-v1` | notarize-only | Scoring engine's rendered disposition (`approve` / `decline` / `refer` + score + reason codes). |
| 09 | `keystone-underwriting-verdict-v1` | **principal-gate** | Human underwriter on refer or contest; a decline requires specific principal reasons (Reg B). |
| 10 | `keystone-adverse-action-notice-v1` | notarize-only | ECOA + FCRA combined notice to the subject: principal reasons required, plus the FCRA score block when a score was used. |

## The screening-engine seam

The sanctions / PEP disposition is rendered by an external screening engine, not by
AGLedger. `keystone-sanctions-screen-v1` captures what that engine returned — the top
score, the match boolean, the list datasets, and the dataset version — and notarizes
it. AGLedger holds the signed record of the disposition; the engine renders it.

Wire your own sanctions/PEP screening engine into this seam. The recipe was exercised
against OpenSanctions yente (POST a person to `/match`, notarize the response), and the
same shape carries a commercial engine — World-Check, ComplyAdvantage, LexisNexis, or
Dow Jones — or an OFAC-only fallback such as Moov Watchman. Always notarize the
screen's `datasetVersion`: it is the audit anchor for which snapshot a hit was
rendered against, and it is what ongoing / perpetual re-screening references.

## The two engine-enforced controls

1. **The score-band gate (03).** Auto-clear versus human-review is an **engine**
   decision from the observed score, not an agent-set `needsReview` / `isHit` boolean.
   `keystone-screening-gate-v1` compares the screening engine's `observedScore` against
   the institution's `clearThreshold` (`number:max-inclusive`): at or below clears
   FULFILLED with no human; above settles FAILED and routes the hit to a Level-1
   analyst. An agent cannot launder a hit past human review by asserting a flag — the
   engine bands the score — and the attempt is still recorded, attributed, and
   tamper-evident. Create the gate with `tolerance:0`: a nonzero tolerance widens the
   band and would silently auto-clear a hit past human review.

   ```
   screening orchestrator ──> 02 sanctions-screen (notarize the engine's disposition)
                          ──> 03 screening-gate (auto)
                               criteria.clearThreshold  vs  completion.observedScore
                               rule: number:max-inclusive
                             ├─ score <= clearThreshold ->  FULFILLED  (auto-clear, no human)
                             └─ score  > clearThreshold ->  FAILED     (escalate to a human)
                                                                │
                                                                v
                                 04 alert-disposition (L1) -> 05 onboarding-decision (L2/MLRO)
   ```

2. **The no-tip-off consistency rule (05/06).** The schema enforces the internal
   consistency of the 31 U.S.C. 5318(g)(2) bar: a `keystone-onboarding-decision-v1`
   that records a SAR was filed must also record the customer notice suppressed
   (`sarFiled ⇒ customerNoticeSuppressed==true`), and a `keystone-regulatory-report-v1`
   of type SAR must affirm the prohibition (`reportType=SAR ⇒
   tippingOffProhibited==true`). A record that claims a SAR while leaving the customer
   notice un-suppressed is rejected. The schema enforces consistency; the deployment
   wires the detective cross-checks, and an agent's honesty about whether a SAR was
   actually filed is the notary boundary — the record is signed and attributed, so it
   is catchable in audit.

## Two-tier separation of duties

The screening orchestrator, the Level-1 analyst (04), and the Level-2 / MLRO officer
(05) are distinct principals. Provision distinct agent keys, ideally
`AGLedger-On-Behalf-Of`-bound to the named humans via your org IdP. AGLedger records
who rendered each verdict, so a single identity that both dispositions an alert and
decides the onboarding is attributable on-chain and catchable in audit. The structural
guard prevents one identity from being both principal and performer within a single
record; cross-tier separation (L1 distinct from L2 across records) is wired by the
deployment through key assignment, and the notary attributes every verdict so the chain
shows who decided what.

## The inverted notice (no tipping off)

A KYC adverse action inverts the credit notice. Under credit ECOA, the substantive
notice flows to the **subject** — the decline, with specific reasons (types 07–10, the
mirror). Under AML, the substantive notice flows to the **regulator** via SAR / FinCEN
and is withheld from the subject; tipping off a SAR subject is a federal crime. So the
two notice legs go to different audiences, and the routing is a deployment
responsibility.

AGLedger Notify subscriptions filter by **event type**, not record type: a regulator
channel and a customer channel both subscribed to `record.created` both receive a
record's `record.created`. The deployment must route and filter so SAR events
(`keystone-regulatory-report-v1`) reach only the regulator channel and never the
subject's channel. `notify.yaml` wires the regulator channel (SAR / OFAC,
ed25519-signed) and the customer channel (ECOA + FCRA) to distinct, type-filtered
receivers — make that filtering explicit at the receiver before fan-out.

## Deployment configuration

- **Screening engine.** Wire your own sanctions / PEP engine into
  `keystone-sanctions-screen-v1`, notarize its rendered disposition, and always capture
  `datasetVersion`.
- **Threshold calibration.** `clearThreshold` is institution policy: document it, keep
  tuning evidence (regulators expect it), and supply it from your risk-based cutoff. The
  recipe makes the threshold-in-force tamper-evident per decision; it does not store the
  calibration study.
- **Gate tolerance.** Create `keystone-screening-gate-v1` with `tolerance:0` so the
  engine bands strictly. Any loosening is recorded on-chain, but supply `tolerance:0`.
- **Separation of duties.** Provision distinct keys for the orchestrator, the L1
  analyst, and the L2 / MLRO; bind verdicts to named humans via `AGLedger-On-Behalf-Of`.
- **Notice routing.** Point the regulator channel and the customer channel at distinct
  receivers that filter by record type before fan-out; route the regulatory report to
  the regulator, never to the subject.

## Install

You administer your own Server, so registering these types *is* the install — no
external registry, no shared signing infrastructure.

```bash
export AGLEDGER_API_URL=https://agledger.internal.example
export AGLEDGER_API_KEY=agl_...   # an admin/platform key with schemas:write
./register.sh
```

`register.sh` POSTs each type to `POST /v1/schemas` in order and prints what landed.
Re-running registers a new version of any type whose schema changed compatibly; an
incompatible change is rejected and reported. See `register.sh` for the
`RECIPE_FORCE=1` reset option (destructive; scratch orgs only).

For the per-call mechanics — preview, compatibility modes, versioning, retiring, and
sharing types across Servers — see the **Define Custom Types** guide. For the Notify
subscriptions in `notify.yaml`, see the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh`
talks only to the `AGLEDGER_API_URL` you give it — your own Server — and makes no
outbound calls to any registry, our website, Docker Hub, or npm. The sanctions / PEP
screening engine is a separate system you operate; an on-premises or air-gapped
screening deployment works the same way — wire `keystone-sanctions-screen-v1` to
whichever engine your environment runs, and AGLedger notarizes whatever disposition it
returns.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit,
rename, or delete any of them. AGLedger ships a deliberately minimal core rather than
opinionated built-in types; a recipe is a head start you own, not a platform-managed
type kept in lockstep with your business.
