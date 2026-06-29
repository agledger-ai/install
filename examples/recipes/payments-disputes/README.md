# Payments disputes / chargebacks: AGLedger vertical recipe

A set of contract types for notarizing the lifecycle of a card dispute and holding the
merchant's **human-authorized, irreversible** decision to contest or concede, before the
terminal action fires. It is a **starting point you adapt**, not a turnkey product: a working
scaffold meant to be imported into your own Server and reshaped to your dispute process and your
payment processor.

This recipe was built and exercised against **Stripe's dispute API** (test mode) as the system of
record. The issuer and the card network render the final won/lost verdict upstream; Stripe relays
it. AGLedger does **not** adjudicate the dispute. It notarizes (a) the filing as received, (b) the
merchant's one genuinely discretionary act (the decision to submit a specific evidence package, or
to concede), and (c) the disposition as relayed. Wire your own processor into the same seam.

## Why a gate here

Stripe evidence submission (`POST /v1/disputes/{id}` with `submit=true`) and concession
(`POST /v1/disputes/{id}/close`) are each **one-shot and terminal**: you cannot edit or resubmit.
The value AGLedger adds is a signed, hash-chained, offline-verifiable record of **who authorized
contesting or conceding, with exactly what evidence, at what time, before the irreversible call.**
Irreversibility is the point: the authorization has to be provable, and it has to predate the act.

## What you get

Six contract types in `types/`, registered in the order below. Two are notarize-only (they record
what happened and terminalize in one signed call); four are principal-gates whose human verdict is
held on-chain.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `chargeback-dispute-filed-v1` | notarize-only | The inbound dispute as the processor reported it (`charge.dispute.created`). The root the decisions reference. |
| 02 | `evidence-submission-decision-v1` | **principal-gate** | A human authorizes contesting with a specific evidence package, before `submit=true`. Evidence is conditional-required by dispute category. |
| 03 | `dispute-concession-decision-v1` | **principal-gate** | A human authorizes conceding via `/close`, the sibling terminal action. |
| 04 | `chargeback-disposition-v1` | notarize-only | The final outcome as relayed (`charge.dispute.closed`): won/lost and funds movement. |
| 05 | `ce3-evidence-submission-decision-v1` | **principal-gate** | The Visa Compelling Evidence 3.0 path (fraud reason 10.4): a human authorizes a structured CE3.0 assertion (disputed transaction + two or more matching priors), hash-bound, after the network renders it `qualified`. |
| 06 | `inquiry-resolution-decision-v1` | **principal-gate** | The inquiry path (Stripe `warning_*`): a human authorizes *refund-to-prevent* (resolve now, no dispute fee) or *respond-with-evidence* (a different decision than the formal chargeback contest/concede). |

## The Stripe seam

Three points connect this recipe to a live processor. The recipe was wired to Stripe; the shape
carries to any processor that exposes a dispute lifecycle.

1. **Filing in.** The `charge.dispute.created` webhook → notarize `chargeback-dispute-filed-v1`.
2. **On the FULFILLED verdict.** Fire the terminal call. Stage the evidence with `submit=false`,
   gate it, then `POST /v1/disputes/{id}` with `submit=true` to contest, or `/close` to concede.
3. **Disposition in.** The `charge.dispute.closed` webhook → notarize `chargeback-disposition-v1`.

## Controls in this recipe

- **Human gate on the irreversible decision.** Every decision type declares
  `defaultGateMode: principal`; a principal (a chargeback or fraud-ops lead) renders accept/reject
  via `POST /v1/records/{id}/verdict`. The performer (an analyst) assembles and submits the
  evidence; the principal is a different identity (separation of duties).
- **Conditional-required evidence by category** (enforced at structural validation, write-time). A
  `product_not_received` package must carry shipping proof or access logs; a `duplicate` package
  must carry the duplicate-charge documentation; a `fraudulent` package must carry IP / email /
  billing. A package missing the category's required fields is rejected
  (`structuralValidation: INVALID`) and the record does not advance: a human cannot authorize an
  incomplete package.
- **Evidence-bytes binding.** The decision carries `evidencePackageHash` (the sha256 of the exact
  object you will submit to the processor); the completion echoes it. An auditor recomputes the hash
  over the actually-submitted evidence and compares. The on-chain authorization is bound to
  specific bytes, so "what did the merchant authorize, and did they alter it after sign-off?"
  becomes a question with a cryptographic answer.

## Lessons for implementers

What we learned building and exercising this recipe: the things worth knowing before you adapt it.

### Set expectations on what the notary does, and does not, do

AGLedger records **who** authorized **what** evidence **when**, tamper-evidently. It does **not**
inspect or detect fabricated evidence; it is a notary, not a verifier. We confirmed this directly:
a fabricated evidence package is accepted and settled, but the chain seals it to the submitting
analyst's identity and an auditor can prove it was not altered. Your control value is *attribution,
human authorization, and tamper-evidence*, not fraud detection. Do not present it as catching bad
evidence.

For anything an auditor relies on, read `GET /v1/records/{id}/audit-export` (or pass
`?integrity=true`), not the plain `GET /v1/records/{id}` body. The plain read is a rewritable
projection; the export offline-verifies (Ed25519 / COSE) against the public key from
`GET /v1/verification-keys`, with no AGLedger code in the loop.

### Bind the exact bytes, and watch your shell

Put the sha256 of the **exact** object you will submit in `evidencePackageHash`, and have the
completion echo it. The 400 envelope tells you the exact format (`^sha256:[0-9a-f]{64}$`) if you
forget the `sha256:` prefix. One real trap this caught:
`curl -d "evidence[uncategorized_text]=…"` splits the value on `;`, silently truncating evidence;
use `--data-urlencode`. Because submission is one-shot you cannot fix it afterward, but the hash
mismatch flags it.

### Stripe system-of-record quirks (test mode, but the shape holds in production)

- `submit` **defaults to `true`** on `POST /v1/disputes/{id}`, and updating any evidence field
  submits all fields. Always **stage with `submit=false` first**, gate, then `submit=true`.
- Forced-outcome test tokens (`winning_evidence` / `losing_evidence`) must be the **exact** value of
  `evidence[uncategorized_text]`; embedding the token in a longer sentence does not resolve.
- Dispute creation is **asynchronous**: poll `GET /v1/disputes?payment_intent=…` or catch
  `charge.dispute.created`; do not assume it is inline after the charge.
- Live dispute ids are **`du_…`** (some older docs still show `dp_…`).
- The Dispute object has **no close timestamp**; derive it from the closing
  `balance_transaction.created` or the `charge.dispute.closed` event time, or leave it off.

### Visa CE3.0: the structured signed-evidence path (`ce3-evidence-submission-decision-v1`)

- **Qualification is the network's verdict, not yours, and it is independent of won/lost.** Stripe
  (proxying Visa) renders the CE3.0 status when you stage the payload; the recipe **holds** that
  status as the network's structural word; it does not compute it. We confirmed the status stays
  `qualified` through a winning close: qualification and outcome are different facts, so notarize
  both. Only propose a package whose staged status is `qualified`.
- **Hash-bind the structured assertion.** Set `evidencePackageHash` to the sha256 of the exact CE3.0
  object (the disputed transaction plus its priors). Because the assertion is what shifts liability,
  binding it makes the merchant's claim (and any later alteration) provable.
- **Let the network enforce cross-transaction matching.** The qualifying signals must be present
  consistently on the disputed transaction and every prior; the network enforces that, and rejects a
  staging POST atomically if a prior is missing identifiers. Have your schema enforce *structural
  completeness* (two or more priors, each with a charge and product description); bind to the
  network's `status` for *qualification*. Do not try to reproduce Visa's qualification rule in your
  schema.
- **Mind the combiner budget.** Expressing CE3.0's "two main, or one main plus one secondary"
  matching rule as a flat `anyOf` needs more branches than the engine allows; the limits are
  discoverable at `GET /v1/schemas/meta-schema` under `constraints`. Collapse it with nested
  `anyOf`/`allOf`: semantically identical, far fewer top-level branches.

### Inquiry vs chargeback: a different class needs a different gate shape

- An **inquiry** (`warning_needs_response`) has not yet become a chargeback, and the merchant's
  discretionary act is different: **refund-to-prevent** (refund now → no dispute fee, stays off the
  dispute ratio) or **respond-with-evidence** (defend). `inquiry-resolution-decision-v1` gates
  exactly that, with the fee at stake on-chain so the economic trade-off is auditable. Route by the
  filing's dispute flow.
- **Capture the network class as data, not as an action.** Stripe abstracts Visa Claims Resolution
  and does not expose allocation-vs-collaboration as distinct merchant actions, nor support
  pre-arbitration. Record the `network_reason_code` and a derived class on the filing for audit and
  routing; do not model a gate the processor cannot drive.
- **Do not hard-code which network carries an inquiry.** Inquiries are not Amex/Discover-only; read
  the brand from the dispute.

### The gate and separation of duties live in your orchestrator, not the type

`gateMode` is a record-creation parameter, not a schema field, so a contract type cannot stop a
caller from creating a decision record with `gateMode: auto` and bypassing the human verdict, on a
rules-less decision type that auto-settles with no human in the loop. Likewise the engine guarantees
only that a performer who is not the principal cannot render the verdict; it does not reject a record
where a single identity is both. So your orchestrator must own the policy: never set `gateMode: auto`
on the decision types, route every `fraudulent` or high-value dispute through the principal gate, and
provision distinct analyst (performer) and lead (principal) identities.

### Keep type descriptions short if you will distribute

`POST /v1/schemas` (register) accepts a long `description`, but `POST /v1/schemas/import` (the
manifest / federation distribution form) rejects descriptions over 2000 characters, so an over-long
description makes the type un-distributable. Put long-form deployment guidance in this README, not in
the schema `description`.

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
rejected and reported. See `register.sh` for the `RECIPE_FORCE=1` reset option (destructive; scratch
orgs only).

For the per-call mechanics (preview, compatibility modes, versioning, and sharing types across
Servers), see the **Define Custom Types** guide. For the Notify subscriptions in `notify.yaml`, see
the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks only to
the `AGLEDGER_API_URL` you give it (your own Server) and makes no outbound calls to any registry,
our website, Docker Hub, or npm. The payment processor is a separate system you integrate; wire the
filing-in and disposition-in webhooks and the terminal call to whichever processor your environment
uses, and AGLedger notarizes whatever it reports.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or delete
any of them. AGLedger ships a deliberately minimal core rather than opinionated built-in types; a
recipe is a head start you own, not a platform-managed type kept in lockstep with your business.
