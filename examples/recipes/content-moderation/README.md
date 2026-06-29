# Content moderation — takedown / DSA enforcement — AGLedger vertical recipe

A set of contract types for notarizing the lifecycle of a content enforcement decision under the
EU **Digital Services Act**: the inbound flag, the platform's own enforcement decision (held behind
a human gate), the Article 17 statement of reasons to the user, the Article 24(5) submission to the
EU DSA Transparency Database, and the Article 20 appeal re-determination. It is a **starting point
you adapt**, not a turnkey product — a working scaffold meant to be imported into your own Server
and reshaped to your moderation policy and your systems.

**The decision is the platform's own.** Unlike the payer, screening, and dispute verticals, there is
**no external system that *renders* the enforcement decision** — a takedown is the platform's call.
So the hero gate is an *own-decision* gate: AGLedger holds the platform's own signed verdict; it
does not adjudicate content or judge whether the call was correct. The one external system in this
recipe is **downstream**: the EU DSA Transparency Database, which platforms submit statements of
reasons to and which returns a receipt. That is the *inverse* of the upstream seam — notarize a
submission *to* a regulator and **bind its receipt**.

## Why gates here

Two consequential acts carry a human verdict:

- **The enforcement decision** — removing or disabling content, or suspending an account, is
  consequential; for account termination, illegal-content grounds, and low-confidence calls it
  should carry a human verdict, not a rubber stamp. (Routine, high-confidence, low-severity,
  fully-automated visibility actions are a legitimate auto-decision path — see the deployment note.)
- **The appeal re-determination (Art. 20)** — the DSA requires complaints be handled under qualified
  human supervision and not solely by automated means; the gate holds that human verdict.

The value AGLedger adds is a signed, hash-chained, offline-verifiable record of *what was flagged,
who or what decided and on what legal ground, the exact statement issued to the user, the exact
payload submitted to the regulator and the receipt that came back, and the appeal outcome* — provable
without trusting the platform's own logs.

## What you get

Five contract types in `types/`, registered in the order below. Three are notarize-only (they record
what happened and terminalize in one signed call); two are principal-gates whose human verdict is
held on-chain.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `content-flag-notice-v1` | notarize-only | The inbound trigger: an Art. 16 notice, a trusted-flagger report, automated detection, or own-initiative. `automatedDetection` records whether it was *detected* by automated means. |
| 02 | `enforcement-decision-v1` | **principal-gate** | The platform's own enforcement decision — the hero own-decision gate. Carries the DSA decision type(s), the ground, conditional-required reasons, and `automatedDecision` (whether the *decision* was automated). |
| 03 | `statement-of-reasons-issued-v1` | notarize-only | The Art. 17 statement delivered to the user; `statementHash` binds the exact reasons. |
| 04 | `dsa-transparency-submission-v1` | notarize-only | The Art. 24(5) submission to the DSA Transparency Database — the downstream seam; `submissionPayloadHash` plus the `dsaUuid` / `dsaPermalink` receipt. |
| 05 | `appeal-redetermination-decision-v1` | **principal-gate** | The Art. 20 appeal verdict: upheld, reversed, or partially reversed. |

## The downstream seam — submit to the regulator, bind the receipt

`dsa-transparency-submission-v1` notarizes the exact JSON you POST to the DSA Transparency Database
(`submissionPayloadHash` = its sha256) and binds the regulator's `201` receipt (`dsaUuid` and
`dsaPermalink`). Together they answer "did the platform report this decision to the regulator, with
these exact reasons, and here is proof of receipt." Cross-checking the user-facing `statementHash`
reasons against the submitted payload makes a user-vs-regulator divergence detectable on-chain.

## Controls in this recipe

- **Human gate on the enforcement decision and the appeal.** Both decision types declare
  `defaultGateMode: principal`. A moderator (performer) submits the determination; a lead or reviewer
  (principal) renders accept/reject via `POST /v1/records/{id}/verdict`. The principal is a different
  identity (separation of duties), and the appeal reviewer is independent of the original decider.
- **Conditional-required DSA reasons** (enforced at structural validation, write-time). At least one
  decision type (visibility / monetary / provision / account) must be present; an `ILLEGAL_CONTENT`
  ground requires a legal ground plus explanation; an `INCOMPATIBLE_CONTENT` ground requires the term
  plus explanation. A determination missing these is rejected and the record does not advance. The
  appeal type mirrors the rule (an upheld verdict requires its basis; a reversal requires the
  reinstatement action).
- **Statement-to-user binding.** `statement-of-reasons-issued-v1.statementHash` is the sha256 of the
  exact Art. 17 statement delivered; an auditor recomputes it over the delivered document.
- **Regulator-submission binding plus receipt.** See the downstream seam above.

## Lessons for implementers

What we learned building and exercising this recipe — the things worth knowing before you adapt it.

### The honesty boundary — what this does, and does not, do

AGLedger is a notary, not a guard. Every enforcement decision, statement, submission, and appeal is
recorded, attributed to a signing identity, hash-chained, and offline-verifiable — but a field like
`automatedDecision` is **self-attested**: AGLedger binds the claim to whoever signed it, it does not
verify the claim is true. An operator who lies about whether an AI made the call, or who skips the
Art. 17 statement, leaves an attributed, tamper-evident gap. That is detection, not prevention — you
own the detective half.

This matters in practice. The user statement (`statement-of-reasons-issued-v1`) and the regulator
submission (`dsa-transparency-submission-v1`) are **both** signed records on the same chain, so a
divergence between what the user was told and what the regulator was told is detectable by
cross-reference. Run that cross-check — statement ground vs submission payload ground — as a periodic
audit; do not assume the field values are true. The control is that the divergence cannot be hidden,
not that it cannot happen.

For anything an auditor relies on, read `GET /v1/records/{id}/audit-export` (or pass
`?integrity=true`), not the plain record body — the export offline-verifies against the public key
from `GET /v1/verification-keys`.

### Model the real regulator schema; make the endpoint a deployment choice

The recipe carries the **real public DSA Transparency Database enums** so the notarized record *is*
the submission. Treat the submission endpoint as configuration, not schema: the `201` can come from
a live self-hosted instance, the production hosted database, or a doc-grounded staging step
(`submissionStatus: pending` until a real receipt is in hand). Do not hard-code the endpoint.

- The hosted database (`https://transparency.dsa.ec.europa.eu/api/v1/statement`) requires onboarding
  via your Digital Service Coordinator (EU Login); there is no open key.
- The official application is open-source and self-hostable
  (`github.com/digital-services-act/transparency-database`).
- **A UI auth wall is not an API auth wall.** The DSA app gates its *web UI* behind EU Login, but its
  *API* authenticates with Laravel Sanctum bearer tokens a self-hoster mints locally — so the
  downstream seam is drivable without any EU credential. Bring up the app, run its migrations and
  seed, then mint a token for a user with the `create statements` permission (the seeded Contributor
  role has it). When an external system "cannot be driven," check whether the wall is only on the
  human UI before settling for doc-grounded.

The real DSA enum keys are **fully prefixed** (`DECISION_GROUND_ILLEGAL_CONTENT`,
`DECISION_VISIBILITY_CONTENT_REMOVED`, `CONTENT_TYPE_TEXT`, `SOURCE_ARTICLE_16`,
`AUTOMATED_DECISION_*`; `automated_detection` is the literal `"Yes"`/`"No"`). The database enforces
its own validation (an `ILLEGAL_CONTENT` submission missing the legal ground is rejected) — AGLedger
holds "this exact payload was submitted, here is the receipt" and does not re-implement that
validation.

### Hash the exact bytes you POST

`submissionPayloadHash` only means something if the hashed bytes are byte-identical to what the
regulator received. Build the payload once into a file, hash that file, and POST that same file — do
not re-serialize between hashing and sending.

### Chain the lifecycle through reference fields, not delegation

The records link through explicit reference fields (`noticeRef` → `enforcementRef` → `statementRef`)
while the org hash-chain binds everything. Do **not** reach for `parentRecordId` delegation to chain
them — delegation would put the whole lineage under a single identity, which defeats the separation
of duties between the moderator, the lead, and the independent appeal reviewer.

### The gate and separation of duties live in your orchestrator, not the type

`gateMode` is a record-creation parameter, not a schema field, so a contract type cannot stop a
caller from creating a decision record with `gateMode: auto` and bypassing the human verdict.
Likewise the engine only blocks a principal from rendering the verdict on a record they performed; it
does not enforce cross-tier role separation. So your orchestrator must own the policy:

- route account-termination, illegal-content grounds, repeat-offender strikes, and low-confidence
  calls through the principal gate, and never set `gateMode: auto` on those;
- provision a moderator identity distinct from the appeal reviewer (Art. 20 independence).

### The high-volume auto-decision path is legitimate — keep it scoped

Content moderation at scale runs large volumes of routine, high-confidence, fully-automated
visibility actions. Those are a legitimate `gateMode: auto` path — the classifier *is* the decider,
and the DSA only requires the *appeal* (not the first decision) to be non-automated. Route only
routine, low-severity, high-confidence, fully-automated visibility actions to auto; everything
consequential goes through the human gate. The auto path is a scale lane, not a bypass of the gates
that matter.

### Keep type descriptions short if you will distribute

`POST /v1/schemas` (register) accepts a long `description`, but `POST /v1/schemas/import` (the
manifest / distribution form) rejects descriptions over 2000 characters. Put long-form deployment
guidance in this README, not in the schema `description`.

## Install

You administer your own Server, so registering these types *is* the install — no external registry,
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

For the per-call mechanics — preview, compatibility modes, versioning, and sharing types across
Servers — see the **Define Custom Types** guide. For the Notify subscriptions in `notify.yaml`, see
the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks only to
the `AGLEDGER_API_URL` you give it — your own Server — and makes no outbound calls to any registry,
our website, Docker Hub, or npm. The DSA Transparency Database is a separate system you submit to;
an on-premises self-hosted instance works the same way — point `dsa-transparency-submission-v1` at
whichever endpoint your environment uses, and AGLedger notarizes the payload and binds the receipt
it returns.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or delete
any of them. AGLedger ships a deliberately minimal core rather than opinionated built-in types; a
recipe is a head start you own, not a platform-managed type kept in lockstep with your business.
