# AGLedger industry recipes

A recipe is a tested set of contract types (and the Notify config to go with them)
for a whole domain workflow — a starting point you import into your own Server and
adapt, so you are not designing every schema from a blank editor. Recipes are
starting points you own, not turnkey products and not platform-managed types.

Each recipe is plain files: a `types/` directory of contract-type registration
bodies, a `register.sh` that POSTs them to your Server in order, and a `notify.yaml`
describing the webhook subscriptions it expects. You administer your own Server, so
running `register.sh` against it *is* the install.

| Recipe | Status | Directory |
|--------|--------|-----------|
| Insurance (auto claims) | Validated reference vertical (API v1.0.3) | [`insurance/`](insurance/) |

More verticals are in development with design partners. If you need one that is not
here yet, contact sales@agledger.ai.

See the **Define Custom Types** and **Webhooks** guides in the documentation for the
per-call mechanics behind `register.sh` and `notify.yaml`.
