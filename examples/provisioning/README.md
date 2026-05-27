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
url: ${WEBHOOK_URL}                          # required — fails if unset
displayName: ${AGENT_NAME:-My Agent}         # with default
secret: ${WEBHOOK_HMAC_SECRET}               # HMAC webhook shared secret
```

Secrets referenced this way must be present in the pod environment. With the
Helm chart, inject them via `extraEnv` / `extraEnvFrom` (see values.yaml) — e.g.
a `secretKeyRef` to an operator-managed Secret — rather than committing the
value to YAML. The engine's own keys (`API_KEY_SECRET`, `VAULT_SIGNING_KEY`, …)
are blocked from substitution.

## Kubernetes ConfigMap

Mount the provisioning directory as a ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: agledger-provisioning
data:
  orgs.yaml: |
    orgs:
      - name: My Org
        ...
```

> Using the AGLedger Helm chart? Don't hand-roll the ConfigMap — declare
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
```

## Directory Structure

```
provisioning/
  orgs/           # Org definitions with inline agents and API keys
  agents/         # Standalone agent definitions (reference their org by name)
  webhooks/       # Webhook subscriptions (reference orgs/agents by name)
  schemas/        # Custom contract type schemas (inline or file references)
```

## Pruning

By default, resources removed from YAML files are left in place (orphaned). To deactivate removed resources on reload:

```bash
export PROVISIONING_PRUNE=true
```
