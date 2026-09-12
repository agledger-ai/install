# Provisioning Examples

Example YAML configuration files for AGLedger's provisioning directory feature. These files demonstrate how to declare orgs, agents, webhooks, and custom contract schemas as code.

## Usage

1. Copy this directory to your desired location:

   ```bash
   cp -r examples/provisioning/ /etc/agledger/provisioning/
   ```

2. Customize the YAML files for your environment.

3. Set the `PROVISIONING_CONFIG_PATH` environment variable:

   ```bash
   export PROVISIONING_CONFIG_PATH=/etc/agledger/provisioning
   ```

4. Start AGLedger. The provisioning directory is read at startup. Resources with `managed_by = 'provisioning'` are reconciled on each boot.

## Hot Reload

Reload without restarting by sending `SIGHUP` or calling:

```
POST /v1/admin/provisioning/reload
```

## Dry Run

Preview what would change without applying:

```bash
export PROVISIONING_DRY_RUN=true
```

## Environment Variable Substitution

All string values in YAML files support `${VAR}` and `${VAR:-default}` syntax. Substitution runs on parsed YAML values (not raw text), so env var contents cannot inject YAML structure.

```yaml
url: ${WEBHOOK_URL}                          # required, fails if unset
displayName: ${AGENT_NAME:-My Agent}         # with default
secret: ${WEBHOOK_HMAC_SECRET}               # HMAC webhook shared secret
```

A bare `${VAR}` with no default is a **hard parse error** when the variable is
unset, and it fails the whole file: every resource in it is skipped, the rest of
the run continues, and the Server boots reporting "Provisioning completed with
errors". Use `${VAR:-default}` wherever a sensible default exists, and check
`GET /v1/admin/provisioning/status` after a config change: it reports the failed
files under `loadErrors`.

Secrets referenced this way must be present in the pod environment. With the
Helm chart, inject them via `extraEnv` / `extraEnvFrom` (see values.yaml), e.g.
a `secretKeyRef` to an operator-managed Secret, rather than committing the
value to YAML. The engine's own keys (`API_KEY_SECRET`, `VAULT_SIGNING_KEY`, …)
are blocked from substitution.

## API keys

Each `apiKeys[]` entry under an org or an agent provisions one `api_keys` row,
keyed on its `label`. There are two shapes.

**Supply the material (recommended for GitOps).** Set `apiKey` to an env-var
reference and the reconciler stores only the HMAC hash of the value:

```yaml
apiKeys:
  - role: admin
    label: gitops-admin-key
    scopeProfile: admin-iac
    apiKey: ${ACME_INTEGRATION_KEY}
```

The key then already exists in your secret store (External Secrets, a sealed
Secret, `extraEnv` / `extraEnvFrom` on the chart) before the Server boots, so
nothing has to be captured out of a response. The same value on the next boot is
a no-change: no re-mint, and no new `ADMIN_KEY_CREATED` audit entry.

Three rules govern supplied material.

**Each entry needs its own value.** `api_keys.key_hash` is UNIQUE, so two
entries referencing one env var (an org key and its inline agent key, say)
cannot both exist. The reconciler reports that as a per-entry error naming the
entry, and provisions the rest of the org normally. Disabling a key does not
release its value for reuse either: a rotation has to introduce new material.

**The value is trimmed, and may not contain whitespace inside it.** A leading
byte-order mark and surrounding whitespace are stripped before hashing, exactly
as the `Authorization: Bearer` parser strips them, so a value that reached the
environment through `kubectl create secret --from-file` (or any `$(cat
key.txt)`) still works with its trailing newline. A value with whitespace in the
middle is refused at load time: it would hash and store fine and could then
never be presented in a bearer header.

**Provisioning never rotates key material in place, and never re-anchors a
stored hash under a new `API_KEY_SECRET`.** Changing the referenced value is
reported as a reconcile error rather than applied silently. So is a hash that no
longer matches because `API_KEY_SECRET` rotated past `API_KEY_SECRET_PREVIOUS`,
which is the same situation from the row's point of view: the stored hash is
dead to the auth hook too, whether or not you changed anything. A GitOps install
therefore has to disable and reload on each `API_KEY_SECRET` rotation, the same
as for a value change. Either way: disable the existing key
(`PATCH /v1/admin/api-keys/{keyId}` with `isActive: false`) and reload, or
declare new material under a new label.

**Let the Server mint one.** Omit `apiKey` and the reconciler generates a random
key. The plaintext is returned in the `POST /v1/admin/provisioning/reload`
response body, under `apiKeys.generated[].apiKey`, and on that one surface only:

```json
{
  "apiKeys": {
    "created": 1,
    "skipped": 0,
    "generated": [
      {
        "ownerName": "Acme Corp",
        "ownerType": "org",
        "label": "primary-api-key",
        "keyId": "019603f1-6a1c-7c9a-9c1e-4f2b8a7d5e30",
        "source": "generated",
        "apiKey": "agl_adm_..."
      }
    ]
  }
}
```

**That readout is one-shot.** The plaintext is never written to the log and
cannot be retrieved afterwards. A boot or SIGHUP reload logs the key id, owner
and label only, so a key minted at startup has no readout at all: mint through
the reload endpoint when you need the value, or supply the material yourself. If
you lose it, disable the key and reload to mint another.

This is why the shipped `orgs/example.yaml` and `agents/example.yaml` declare no
keys. Both shapes are there, commented, with the env var to set for the first
and the reload call to make for the second. Copying the starter directory
verbatim provisions the org and the agents and no credential, so a first boot
cannot leave you holding an admin key nobody can read.

## Kubernetes ConfigMap

Mount the provisioning directory as a ConfigMap. Only the four subdirectories
below are read, and a ConfigMap key cannot contain `/`. The key names the file;
`items[].path` puts it in its subdirectory. A file mounted at the provisioning
root instead is never opened, and the Server starts with nothing provisioned:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: agledger-provisioning
data:
  my-org.yaml: |
    orgs:
      - name: My Org
```

> Using the AGLedger Helm chart? Don't hand-roll the ConfigMap: declare
> provisioning content under `provisioning.*` in values.yaml; the chart renders
> and mounts it for you.

Then in your Deployment or Helm values:

```yaml
env:
  - name: PROVISIONING_CONFIG_PATH
    value: /etc/agledger/provisioning

volumeMounts:
  - name: provisioning
    mountPath: /etc/agledger/provisioning

volumes:
  - name: provisioning
    configMap:
      name: agledger-provisioning
      items:
        # `path` is what creates the subdirectory. Without it the file lands at
        # /etc/agledger/provisioning/my-org.yaml, which nothing reads.
        - key: my-org.yaml
          path: orgs/my-org.yaml
```

## Directory Structure

```
provisioning/
  orgs/                  # Org definitions with inline agents and API keys
  agents/                # Standalone agent definitions (reference their org by name)
  webhooks/              # Webhook subscriptions (reference orgs/agents by name)
  schemas/               # Custom contract type schemas (inline or file references)
  trusted-issuers.yaml   # IdP trust anchors, at the provisioning ROOT (not a directory)
```

`trusted-issuers.yaml` sits at the root rather than in a subdirectory, and it is
the only config-as-code door to `autoProvisionAgents`. A minimal entry:

```yaml
trusted_issuers:
  - issuerUrl: https://login.microsoftonline.com/TENANT/v2.0
    expectedAudience: agledger
    appliesTo: agent
    orgId: 018f2b6c-1234-7abc-8def-0123456789ab
    # jwksUri is auto-discovered from the issuer's OIDC well-known when omitted.
    claimMapping:
      scopes: agledger_scopes
    # Create an agent on first exchange for a subject we have not seen.
    # Requires orgId: a global row names an IdP but no tenant, so there is no
    # answer to which org a new agent would belong to.
    autoProvisionAgents: true
    autoProvisionScopeProfile: agent-full
    autoProvisionMaxAgents: 50
```

Every key is validated at load, and a key this loader does not read is refused
rather than ignored, because the defaults applied in place of an ignored key are
the permissive ones. Removing an entry deletes the row, EXCEPT when it has
already minted ephemeral certs: the cert ledger needs the issuer row to stay in
place, so that deletion is reported and skipped. Set `enabled: false` on the
entry instead to stop accepting new tokens while issued certs run to expiry.

## Schema entries

Each entry under `schemas:` uses the same top-level placement as `POST /v1/schemas` for the keys it supports: `type`, `recordSchema`, `completionSchema`, and optionally `displayName`, `description`, `category`, `fieldMappings`, and `defaultGateMode`. Gate rules go in `fieldMappings` at the top level, exactly as in a register body (see `schemas/example.yaml`). Register fields outside that list (`compatibilityMode`, `defaultShare`, `coSignRequired`, and the other row-only federation toggles) are not provisioning-configurable; declaring them, or any other unknown key, fails the entry at load time rather than silently dropping it, so misplaced gate config can never provision a type that enforces nothing. The entry is what fails, not the file: the valid entries beside it still reconcile. What a failed entry does cost is pruning, which is suppressed for the whole run (see [Pruning](#pruning)). Every failed entry is reported under `loadErrors` on `GET /v1/admin/provisioning/status`, and a key or shape the entry validators reject is also logged as a WARN naming the file and the entry index. Rule wiring is validated at load with the same checks as the register API: malformed mapping elements, duplicate ruleIds, unknown verbs, and criteria/evidence paths that do not resolve against the schemas each fail the entry with a per-type error.

The schema bodies themselves are validated at load too, by the same meta-schema walk and Ajv trial compile `POST /v1/schemas` runs. A `recordSchema` or `completionSchema` must be a JSON object with `type: object` and a non-empty root `required` array; `$id`, `$data`, `$code`, `$async`, `prefixItems` and `contentSchema` are rejected; `format` must be one of the allowed values; regexes are checked for catastrophic backtracking; the body is bounded at depth 5, 200 nodes and 50 KB; and it must compile under Ajv, so a typo like `type: strng` fails here rather than on the first record. `GET /v1/schemas/meta-schema` serves the authoritative constraints, including the allowed formats and applicator keywords.

Write `completionSchema: {}` for a notarize-only type. A bare `completionSchema:` is YAML null and is refused, and `{"type": "object", "additionalProperties": false}` is not treated as empty: it has no root `required`, so it is refused like any other body without one.

The one register-API check not run here is compatibility against existing versions, which needs a database round-trip this loader does not make. Everything else the register API validates without touching the database runs at load, including the reserved-record-field guard.

A schema entry that fails any of this is skipped with a per-type error, and the rest of the directory still applies. The previously provisioned version of that type stays live and stays managed.

The same per-entry rule holds for `orgs/`, `agents/` and `webhooks/`: an entry that fails its own validation is skipped and its siblings load. A file is skipped whole only when the document itself is unreadable: a YAML parse error (including a bare `${VAR}` with no default, above), or a missing `orgs:` / `agents:` / `webhooks:` / `schemas:` array. In every partial case prune is suppressed, because an absence in a config that did not fully load cannot be read as a deliberate removal. The one check that spans entries rather than living inside one, two agents claiming the same `oidcIss` + `oidcSub`, is reported but does not skip either entry: it is refused at apply time by the unique index, per agent.

<!-- v1.6.0 peer shim: remove after the next release, with the section below. -->

### Upgrading from 1.6.0

Two pieces of 1.6.0 vocabulary are accepted and ignored for one release, so a directory carried over from that version reconciles without an edit. Both log a WARN at load naming the file and what was dropped, and both are removed in the release after this one. Fix the files now.

- `commissionSourceField` on a `schemas:` entry is dropped. Commission was removed after 1.6.0: none is computed, stored or served, so the key changes nothing about the type that gets registered.
- `dispute.escalated` and `record.proposal_counter_proposed` are dropped from a subscription's `eventTypes`. Neither is emitted any more, so the subscription delivers the same events with or without them. A subscription that names **only** removed types is the one case that fails the entry: "every event" and "no subscription" are both honest readings of what is left, and the loader will not guess. Give it the event types you want, or `['*']`, or delete it.

## Pruning

By default, resources removed from YAML files are left in place (orphaned). To offboard removed resources on reload:

```bash
export PROVISIONING_PRUNE=true
```

For an org or agent, a prune is a full offboarding in one transaction: its API keys are revoked, management is released (`managed_by` becomes NULL) and the account is deactivated. A deactivated account refuses every credential bound to it, including an SSO bearer and a live ephemeral cert, and `POST /v1/admin/api-keys` refuses to mint it a new one. Confirm it on `GET /v1/admin/orgs` or `GET /v1/admin/agents`, which report `deactivatedAt` and `managedBy` per row. To undo it, `POST /v1/admin/{orgs|agents}/{id}/reactivate` with a platform credential; a platform key is bound to neither an org nor an agent, so it still authenticates after a prune that took every org offline.

Webhook subscriptions are deactivated the same way. A pruned schema type is only un-managed, not withdrawn: it stays registered and servable, so records already written against it keep validating.

A pruned name is not re-adoptable. Putting it back in the YAML does not pick the row up again, because the row is no longer managed and the reconciler will not adopt a resource it did not create; it reports the name as in use instead. Reactivate the existing row rather than re-declaring it.

Pruning is skipped entirely for any reload whose config did not load cleanly, and the run reports that it was skipped. Absence from a broken config is not evidence that the operator removed anything, so a file with a typo in it never causes the resources it declares to be un-managed. Fix the reported load errors and reconcile again to prune.
