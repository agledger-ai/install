# AGLedger industry recipes

A recipe is a tested set of contract types (and the Notify config to go with them)
for a whole domain workflow: a starting point you import into your own Server and
adapt, so you are not designing every schema from a blank editor. Recipes are
starting points you own, not turnkey products and not platform-managed types.

Each recipe is plain files: a `types/` directory of contract-type registration
bodies, a `register.sh` that POSTs them to your Server in order, and a `notify.yaml`
describing the webhook subscriptions it expects. You administer your own Server, so
running `register.sh` against it *is* the install.

| Recipe | What it covers | Directory |
|--------|----------------|-----------|
| Insurance: auto claims | First notice of loss through coverage, property and bodily-injury assessment, fraud and SIU review, an engine-decided authority gate, and the human settlement decision. | [`insurance/`](insurance/) |
| Healthcare: prior authorization | A PA decision rendered by the payer's utilization-management system (HL7 Da Vinci PAS); contested cases routed to a medical director. | [`healthcare-prior-auth/`](healthcare-prior-auth/) |
| Finance: KYC / sanctions adverse action | Sanctions and PEP screening (built against OpenSanctions), an engine-decided score-band gate, two-tier review, and the regulator-facing no-tip-off notice. | [`finance-kyc/`](finance-kyc/) |
| Payments: disputes / chargebacks | The card-dispute lifecycle with a human-authorized, one-shot decision to contest or concede (built against Stripe's dispute API), the evidence package hash-bound before submission, plus the Visa CE3.0 and inquiry paths. | [`payments-disputes/`](payments-disputes/) |
| Content moderation: DSA takedown / enforcement | The EU Digital Services Act enforcement lifecycle: inbound flag, a human-gated own-decision, the Art. 17 statement to the user, the Art. 24(5) submission to the DSA Transparency Database with its receipt bound on-chain, and the Art. 20 appeal. | [`content-moderation/`](content-moderation/) |
| Software delivery: GitHub | An agent-driven code-delivery flow: the agent's stated intent and claims, the CI conclusion relayed hash-bound, the human merge or deploy authorization rendered before the sha-pinned one-shot (built against live GitHub), and the outcome as GitHub reports it. Composes AGLedger's Gate with GitHub's native gates under a one-decision-one-holder rule. | [`software-delivery/`](software-delivery/) |
| Tax: HMRC MTD VAT filing | A UK VAT return filed to HMRC under Making Tax Digital: the open obligation, the nine-box return, an engine pre-flight arithmetic gate, the officer's statutory "true and complete" declaration held before the irreversible submission, and HMRC's form bundle number or typed rejection bound to the exact bytes filed (built against the HMRC developer sandbox). | [`hmrc-mtd-vat/`](hmrc-mtd-vat/) |
| Employment: FCRA adverse action | Background screening where the gate is a clock: the CRA's adjudication notarized at the seam (built against the Accurate Background sandbox), an engine auto-clear vs human-review gate, the EEOC individualized assessment, the FCRA pre-adverse notice that starts the wait, an engine-enforced waiting period that refuses a too-early final action, and the 615(a) final decision with the interval provable offline from two signed timestamps. | [`employment-fcra/`](employment-fcra/) |

We add and exercise new verticals over time. If you need one that is not here yet,
contact sales@agledger.ai.

See the **Define Custom Types** and **Webhooks** guides in the documentation for the
per-call mechanics behind `register.sh` and `notify.yaml`.
