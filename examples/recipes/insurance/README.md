# Insurance claims — AGLedger vertical recipe

A tested set of contract types for notarizing an automated auto-insurance claims
pipeline on AGLedger, plus the Notify subscriptions it expects. It is a **starting
point you adapt**, not a turnkey product — a working scaffold meant to be imported
into your own Server and reshaped to your carrier's process and systems of record.
("Meridian" is a sample carrier; rename the types to whatever you like.)

**What AGLedger does here:** it records each step's intent and outcome — attributed,
hash-chained, and tamper-evident — and holds the verdict on the settlement. It is a
notary, not an adjudicator: it does not judge whether a fraud score, damage estimate,
or payout is *correct*; it records what was decided, by whom, and when.

This recipe was shaped by running the full pipeline cold across multiple agent
models, at scale, on live cloud infrastructure — with live Notify delivery and
offline chain verification — so the authority gate and the settlement hand-off hold
up under real agent behavior.

## What you get

Ten contract types in `types/`, registered in the order below. Eight are
notarize-only (they record what happened and terminalize in one signed call); two
are prescriptive gates whose output has to conform.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `meridian-claim-intake-v1` | notarize-only | First Notice of Loss; the root record every step references by `claimNumber`. |
| 02 | `meridian-coverage-check-v1` | notarize-only | Coverage determination; a denial requires both a factual and legal basis (`if determination=denied then …`). |
| 03 | `meridian-damage-assessment-v1` | notarize-only | Property/vehicle loss estimate, method, and evidence reference. |
| 04 | `meridian-fraud-score-v1` | notarize-only | Fraud score; an SIU referral requires red flags + a referral reference (`if referSIU=true then …`). |
| 05 | `meridian-siu-referral-v1` | notarize-only | Flag-and-refer to the human SIU; the referring agent cannot also settle the claim. |
| 06 | `meridian-authority-band-v1` | **auto-gate** | The **engine** decides if the proposed amount is within the band ceiling. FULFILLED = within authority; FAILED = over → escalate. |
| 07 | `meridian-settlement-decision-v1` | **principal-gate** | The human-verdict override path, entered only when the band check FAILED (or a flag forces review). |
| 08 | `meridian-settlement-outcome-v1` | notarize-only | Terminal posted outcome + system-of-record reference + downstream notify targets. |
| 09 | `meridian-reserve-v1` | notarize-only | Claim reserve (evolving ultimate-cost estimate) with amount/type/basis; history via `supersedesRef`. |
| 10 | `meridian-injury-assessment-v1` | notarize-only | Bodily-injury counterpart to `03`: a medical-specials / future-medical / lost-wages / general-damages buildup. |

Beyond the linear spine, the types model **multi-exposure** claims (one accident,
several exposures — collision, third-party property, bodily injury — each settling
on its own sub-chain under one `claimNumber` via `exposureId`), **reserves** with
indemnity/expense revisions, and **appeals** that re-determine against an original
outcome.

### The authority model

Settlement authority is decided by the **engine**, not asserted by the agent. The
`meridian-authority-band-v1` auto-gate compares the agent's `proposedAmount` against
an operator-configured `authorityCeiling` (`denomination:max-inclusive`): within the
ceiling settles FULFILLED; over it settles FAILED and routes to the human override
path (`meridian-settlement-decision-v1`, a principal-gate). An agent can no longer
assert its way past the ceiling — and the over-authority attempt is still recorded,
attributed, and tamper-evident. Band ceilings are operator policy: configure a
per-band table (illustrative: junior $10k, senior $50k, manager $250k, committee
above) and supply `authorityCeiling` from it; do not invent a ceiling per claim.

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
outbound calls to any registry, our website, Docker Hub, or npm.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit,
rename, or delete any of them. AGLedger ships a deliberately minimal core rather than
opinionated built-in types; a recipe is a head start you own, not a platform-managed
type kept in lockstep with your business.
