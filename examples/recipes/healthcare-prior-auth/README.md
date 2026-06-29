# Healthcare prior-authorization: AGLedger vertical recipe

A set of contract types for notarizing an automated prior-authorization (PA) pipeline
on AGLedger, plus the Notify subscriptions it expects. It is a **starting point you
adapt**, not a turnkey product: a working scaffold meant to be imported into your own
Server and reshaped to your payer's utilization-management process and systems of
record. ("Halcyon" is a sample plan name; rename the types to whatever you like.)

**What AGLedger does here:** in prior-auth the medical-necessity decision is rendered by
the payer's utilization-management system (and, for contested cases, by the payer's
medical director), never by AGLedger. AGLedger notarizes what the payer system decided
(attributed, hash-chained, and tamper-evident) and holds the medical director's verdict
at the seam. It is a notary, not an adjudicator: it does not judge whether a denial was
correct; it records what was decided, by whom, and when. The payer system and the
medical director are the deciders.

This recipe was built and exercised against a reference HL7 Da Vinci payer system (the
Burden-Reduction br-payer Prior Authorization Support service) driving real PAS
`$submit` calls and the X12 review-action codes it returns, so the gate hand-off matches
how an actual payer renders prior-auth decisions.

## The pattern: decide at the system-of-record seam

The defining choice of this recipe is **where the decision is rendered.** The
medical-necessity determination comes from the payer's utilization-management system over
Da Vinci PAS / X12 278; AGLedger captures it at the seam rather than re-deriving it:

```
  Provider           Payer system of record (Da Vinci PAS / X12 278)     AGLedger (notary + gate)
  ────────           ───────────────────────────────────────────────    ────────────────────────
  submit PA   ─────▶  $submit → ClaimResponse (X12 review action)
                      A1 certified / A3 not-required  ───────────────▶  notarize disposition (terminal)
                      A2 denied / A4 pended (contested) ──────────────▶  notarize disposition
                                                                          → medical director renders
                                                                            the verdict via the Gate
                                                                          → signed, offline-verifiable chain
```

Clean auto-adjudications (A1 certified, A3 not-required) are notarize-only and terminal:
roughly the 90% path. The notary earns its place on the contested path: A2 (denied) and
A4 (pended) route to a medical director, whose accept/reject verdict AGLedger holds and
signs. An appeal appends a fresh re-determination without rewriting the original chain.

## What you get

Four contract types in `types/`, registered in the order below. Two are notarize-only
(they record what happened and terminalize in one signed call); two are principal-gates
whose verdict is rendered by a human and held by AGLedger.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `halcyon-pa-request-v1` | notarize-only | The PA request as submitted by the provider: the signed "this is what we submitted" artifact, carrying the urgency that starts the 72h-expedited / 7-day-standard decision clock. The root record every step references by `claimId`. |
| 02 | `halcyon-pa-disposition-v1` | notarize-only | The payer system's auto-adjudication (Da Vinci PAS `ClaimResponse`, X12 review-action code) captured at the seam. A1/A3 terminal; A2/A4 escalate. |
| 03 | `halcyon-pa-determination-v1` | **principal-gate** | The medical director's verdict on a contested disposition. `denialBasis` is conditional-required when a denial is upheld. The hero gate. |
| 04 | `halcyon-pa-appeal-v1` | **principal-gate** | Appeal, peer-to-peer, or external-IRO re-determination via `appealOfRef`; appends, never rewrites. |

## Install

You administer your own Server, so registering these types *is* the install: no external
registry, no shared signing infrastructure.

```bash
export AGLEDGER_API_URL=https://agledger.internal.example
export AGLEDGER_API_KEY=agl_...   # an admin/platform key with schemas:write
./register.sh
```

`register.sh` POSTs each type to `POST /v1/schemas` in order and prints what landed.
Re-running registers a new version of any type whose schema changed compatibly; an
incompatible change is rejected and reported. See `register.sh` for the `RECIPE_FORCE=1`
reset option (destructive; scratch orgs only).

For the per-call mechanics (preview, compatibility modes, versioning, retiring, and
sharing types across Servers), see the **Define Custom Types** guide. For the Notify
subscriptions in `notify.yaml`, see the **Webhooks** guide.

## Deployment requirements

The recipe gives you the chain; the deployment wires the cross-checks around it.

- **Wire your payer feed.** Drive your payer system's PAS `$submit` (or consume its X12
  278 response or decision event), map the disposition into `halcyon-pa-disposition-v1`,
  and route A2/A4 to a `halcyon-pa-determination-v1`. The X12 review-action code is the
  join. Adjudication stays in your payer system; AGLedger records the disposition it
  returned.
- **Separation of duties.** AGLedger records who rendered each verdict, so provision a
  distinct medical-director key separate from the clinical-reviewer performer that
  submitted the recommendation; the reviewer and the director stay different identities
  on the chain. Bind the named physician to the verdict via `AGLedger-On-Behalf-Of`
  against your org IdP.
- **PHI handling.** The types carry de-identified references (`memberRef`), not member
  PHI. Keep clinical content behind your own systems and notarize references and
  decisions.
- **Notify and SSRF.** Webhook deliveries to a private or in-cluster sink need
  `SSRF_ALLOW_CIDRS`; private, link-local, and metadata IPs are blocked at connect
  otherwise. Use `signingAlg: ed25519` for offline-verifiable deliveries.
- **CMS-0057-F mapping.** `urgency` drives the 72h-expedited / 7-day-standard decision
  clock; the determination's `denialBasis` and `denialReasonCode` carry the
  specific-denial-reason obligation. Your operator owns conformance; the recipe provides
  the tamper-evident scaffolding for it.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh`
talks only to the `AGLEDGER_API_URL` you give it (your own Server) and makes no
outbound calls to any registry, our website, Docker Hub, or npm.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename,
or delete any of them. AGLedger ships a deliberately minimal core rather than opinionated
built-in types; a recipe is a head start you own, not a platform-managed type kept in
lockstep with your business.
