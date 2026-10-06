# AGLedger Install

Install scripts, Docker Compose files, and Helm chart for [AGLedger](https://agledger.ai).

AGLedger is a cryptographic notary for automated operations. An agent notarizes what it is about to do, then notarizes what was done. Both are signed and hash-chained. For workloads where the deliverable is measurable (procurement, finance, compliance), an optional gated mode adds a receipt + verdict phase. AGLedger does not inspect or judge deliverable content; it records what was claimed and when, signed and chainable.

This repository contains only the deployment packaging. The server image is distributed on [Docker Hub](https://hub.docker.com/r/agledger/agledger) and the Helm chart on OCI at `oci://registry-1.docker.io/agledger/agledger-chart`.

## Prerequisites

- Docker Engine 24.0 or later
- Docker Compose 2.23.1 or later (the compose file uses an inline `configs.content`; older Compose
  fails to parse it, so `up`, `down`, `logs` and `ps` all break)
- 4 GB RAM minimum (8 GB recommended)
- 2 CPU cores minimum (4 recommended)
- 20 GB free disk

## Quick Start

```bash
git clone https://github.com/agledger-ai/install.git
cd install
./scripts/install.sh
```

The API is reachable at `http://localhost:3001` once startup completes. The OpenAPI document is served at `http://localhost:3001/openapi.json`, and `/docs` redirects to the hosted reference at https://agledger.ai/api. To browse an API explorer on the install itself, which is what an air-gapped host needs, set `SWAGGER_UI_ENABLED=true` in `compose/.env` and run `docker compose up -d agledger-api`. That recreates the container, which is what picks the value up: the API reads `.env` through `env_file`, and a container's environment is fixed when it is created, so `docker compose restart` brings the old value back with it.

`install.sh` generates cryptographic secrets locally, writes `compose/.env`, starts PostgreSQL, runs migrations, creates a platform API key (printed once, so save it), and starts the API and worker.

A fresh install with no `--version` takes the latest release from Docker Hub and records it in `compose/.env`. Every later run of `install.sh` stays on that version, so re-running it is safe: it reconciles configuration and never moves the install between releases. That holds once the recorded version is a release number; if `compose/.env` still names something else, a non-release tag from a testbed build or air-gap mirror, or the `.env.example` placeholder `latest` never overwritten, a plain re-run cannot tell a deliberate pin from a placeholder and refuses instead of guessing, naming both `--version` (stay on it) and `upgrade.sh` (move) as the ways forward. A re-run that changes anything in `compose/.env` recreates the containers whose configuration changed, so the repair is live when the run ends rather than pending a restart you were not told about; a re-run that changes nothing leaves every container alone. That covers the secrets a newer release expects and an older install has none of, such as the `/metrics` scrape token, and it covers the monitoring stack: if the collector, Jaeger, Prometheus and Grafana are running, a plain re-run brings them with it whether or not you pass `--with-monitoring`. Two of those are the exception to "changes nothing, touches nothing": the collector and Prometheus read their whole configuration once, at start, from a file mounted out of this checkout, and Compose hashes the service definition rather than that file's contents, so every run restarts those two and says so. It is how a configuration change reaches them at all, and neither holds anything: Prometheus keeps its series on the named `prometheus-data` volume and the collector holds at most one five-second batch. If the registry is unreachable and `compose/.env` already pins a digest this host holds locally, the run says so and reconciles on those bytes instead of refusing; nothing is verified on such a run. Changing releases is `upgrade.sh`, which backs up first and writes the marker that says what to roll back to:

```bash
./scripts/upgrade.sh X.Y.Z   # the release you are moving to
```

`install.sh --version X.Y.Z` on an install already at another version is honored, because you asked for it by name, but it takes no backup and warns you to use `upgrade.sh` instead.

## Deployment Paths

### Docker Compose (default)

Single-node deployments, evaluation, and small-to-medium workloads.

```bash
./scripts/install.sh
```

All configuration lives in `compose/.env`. See `compose/.env.example` for the full list of variables.

The stack runs under the compose project named after the `compose/` directory, so its containers, network and `compose_pgdata` volume belong to the Docker host rather than to a particular checkout. Two checkouts on one host share one database, `docker compose down -v` in either destroys it for both, and the volume survives deleting the checkout that created it. `install.sh` refuses to generate fresh credentials against a volume that already exists (Postgres keeps the password it was initialized with, so the new ones would fail authentication) and tells you how to keep it, discard it, or install beside it. To give a checkout its own containers and data instead, set the project name on a checkout that is not already installed. Host ports are global to the machine, so a stack running alongside another needs its own there too:

```bash
COMPOSE_PROJECT_NAME=agledger-2 AGLEDGER_HOST_PORT=3011 POSTGRES_HOST_PORT=5442 ./scripts/install.sh
```

The name is written into `compose/.env`, so later `docker compose` commands and `upgrade.sh` stay on the same project.

That file is also why a second stack needs a second directory. There is one `compose/.env` per checkout and it is the entire state of the install that lives there: host ports, `COMPOSE_PROJECT_NAME`, `VAULT_SIGNING_KEY`, `PLATFORM_API_KEY`, `AGLEDGER_EXTERNAL_URL`. Re-running `install.sh` under a new project name in a directory that already holds an install would leave the first stack running while rewriting the only file that points at it, so `install.sh` refuses and prints the copy recipe:

```bash
cp -r <this-install> ../agledger-2 && cd ../agledger-2
rm -f compose/.env compose/.env.backup-*   # so the new stack generates its own secrets rather than signing under the first one's key
rm -rf backup                              # and does not start out holding the first stack's archives and rollback marker
COMPOSE_PROJECT_NAME=agledger-2 AGLEDGER_HOST_PORT=3011 POSTGRES_HOST_PORT=5442 ./scripts/install.sh
```

Each checkout keeps its own `backup/` directory, so the two stacks' archives and their rollback markers stay apart, and a `backup.sh --keep` run in one cannot delete the other's. Everything under a backup directory carries the compose project name (the archives, the staging directory, the rollback marker), so pointing both stacks at one `BACKUP_DIR` is safe too.

The refusal is scoped to a directory whose stack still exists. After `uninstall.sh` (which keeps `compose/.env` so a reinstall preserves the signing key) there is nothing left to orphan, so the same checkout can be reinstalled under any project name.

### Kubernetes (Helm)

Production clusters:

```bash
helm install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger --create-namespace \
  --values your-values.yaml
```

Reference values: `helm/agledger/values.yaml`. Or run `./scripts/helm-install.sh` for a guided install that generates secrets and produces a values file. It defaults to the Docker Hub chart and image; `--chart` takes an `oci://` reference on your own registry or a local `.tgz` from `helm pull`, and `--image` takes your mirror, so the guided path works inside an enclave. It says on such a run that it verified nothing, because a release signature is an OCI referrer on Docker Hub and does not travel with a mirrored copy. See [air-gap/README.md](air-gap/README.md).

`config.externalUrl` is required. It becomes `AGLEDGER_EXTERNAL_URL`, the issuer signed into every
record, receipt and certificate, and it is permanent: rows already written keep the issuer they were
signed with, so changing it later splits the chain rather than correcting it. A production render
that supplies neither this nor an ingress host is refused rather than defaulted. For a single node
with no domain, set it to `https://localhost` yourself.

**The database is either the chart's bundled PostgreSQL or one of your own, and `database.externalUrl`
decides which.** `postgres.bundled.enabled: true` runs the bundled container; `database.externalUrl`
points the release at Aurora, RDS, Cloud SQL, or a self-managed server. `database.externalUrl` wins
over the bundled flag: the chart renders no bundled PostgreSQL even when a values file or an earlier
install left `postgres.bundled.enabled` true, and the release is an external-database one in every
other respect too. The migration runs as a pre-install hook, the runtime-role gate below runs, database
egress leaves the cluster, and the chart sets no `ALLOW_DB_WITHOUT_SSL`, so the Server's production
`sslmode=` requirement stands. Setting neither value is refused by name rather than installed without a
database, unless `secrets.existingSecret` is set, where the chart writes no Secret and those keys are
yours to supply. Switching an existing bundled release to an external database drops the bundled PVC
from the release, exactly as setting `postgres.bundled.enabled: false` does, and on the default
`Delete` reclaim policy that takes the volume with it, so back it up first if you want what is on it.

**Upgrades keep the values you installed with.** Pass the same values file every time. `--reuse-values`
looks like the shortcut and is not: it re-coalesces the previous release's chart defaults, so every
default a newer chart version changes is pinned to the old one and nothing says so.
`--reset-then-reuse-values` (helm 3.14 and later) is the flag that does what `--reuse-values` is
usually reached for, taking the new chart's defaults and laying the last release's own values over
them. `./scripts/helm-install.sh` uses it: re-running the quick-start against an existing release
reconciles that release in place rather than refusing its name.

**Syncing this chart from Argo CD, or any `helm template | kubectl apply` pipeline, needs
`secrets.gitops: true`.** The chart generates `API_KEY_SECRET`, `POSTGRES_PASSWORD` and
`METRICS_AUTH_TOKEN` when nothing supplies them, and preserves them across upgrades by reading the
release Secret back with `lookup`. `lookup` talks to the API server, which a renderer does not: under
`helm template` it returns nothing, every sync regenerates, and every API key issued against the last
`API_KEY_SECRET` stops authenticating with no rotation logged anywhere. There is no in-template flag
that tells a render from an install, so this is a value you set; it turns each of those fallbacks into
a render failure naming what to supply. The path it points at is `secrets.existingSecret`, a Secret
your platform manages (External Secrets, Sealed Secrets, SOPS), which makes the chart write no Secret
at all. Flux's helm-controller runs real helm releases against the cluster, so `lookup` works there
and this can stay false.

`RATE_LIMIT_STORE` is derived: `postgresql` when `api.replicaCount` is above 1 or the HPA is on,
`memory` on a single replica. In-memory counters are per pod, so two replicas admit twice the
advertised limit. Override with `config.rateLimitStore`.

External IdP trust is a values-file concern on Kubernetes, not an admin-API one: `provisioning.trustedIssuers`
renders `trusted-issuers.yaml`, and `provisioning.existingConfigMaps.trustedIssuers` mounts a ConfigMap you
manage (its key has to be named `trusted-issuers.yaml`). Either way the chart projects it as a directory at
`<configPath>/trusted-issuers/`, so `kubectl apply` on the ConfigMap followed by
`POST /v1/admin/provisioning/reload` applies the change without restarting the pods.

**Monitoring.** With the Prometheus Operator installed, the chart ships its own alerts and dashboards
rather than leaving you to copy YAML:

```bash
helm upgrade agledger ... \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.prometheusRule.enabled=true \
  --set monitoring.grafanaDashboards.enabled=true
```

These render the same rule and dashboard files the Compose stack mounts, so the two packaging paths
cannot drift. Retune a shipped alert without forking that file with
`--set monitoring.prometheusRule.overrides.AGLedgerHighLatency.severity=warning`, which also takes
`for`, `keepFiringFor`, a replacement `expr`, and `disabled: true` to drop the rule; an override
naming an alert that does not exist fails the render rather than doing nothing. Add your own groups
under `monitoring.prometheusRule.additionalGroups`, and point every alert's `runbook_url` at an
internal wiki with `--set monitoring.prometheusRule.runbookUrl=https://wiki.example.com/agledger`,
which keeps the per-alert `#<lowercase alert name>` anchors.
`GET /metrics` is gated under `NODE_ENV=production`, which the chart sets: it mints a
bearer token into the release Secret, preserved across upgrades, and the ServiceMonitor presents it.
Read it with `kubectl get secret -n <ns> -l app.kubernetes.io/instance=<release> -o jsonpath='{.items[0].data.METRICS_AUTH_TOKEN}' | base64 -d` (by label: the chart renders one Secret, and its name depends on your release name and `fullnameOverride`)
for a Prometheus you run yourself.

#### OpenShift

Add `--set openshift.enabled=true`:

```bash
helm install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger --create-namespace \
  --set openshift.enabled=true \
  --values your-values.yaml
```

`openshift.enabled` also admits the OpenShift router in the API NetworkPolicy. Without it the router
cannot reach the pods and an admitted Route answers 503 with nothing in the pod logs. For a native
Route instead of an Ingress, `--set route.enabled=true --set route.host=<host>`; enable one or the
other, since the router turns an Ingress into a Route of its own and two objects would claim the same
hostname.

OpenShift's default `restricted-v2` SCC assigns uids from a per-namespace range and admits pods with `MustRunAsRange`. The chart's stock `podSecurityContext` asks for 65532, outside that range on essentially every cluster, so without the flag admission refuses the pods, naming a uid the operator never chose (`runAsUser: Invalid value: 65532: must be in the ranges: [...]`). The flag drops the pod-level block from all three workloads (api, worker, migrate Job) and lets the platform assign a uid.

That block is `runAsNonRoot: true` plus the two uid/gid keys, so non-root stops being asserted in the manifest: on OpenShift `restricted-v2` enforces it directly, and elsewhere it rests on the image's own `USER 65532:65532`. Every container-level control is untouched either way (read-only root filesystem, no privilege escalation, all capabilities dropped). The bundled PostgreSQL needs no equivalent, since it requests no securityContext at all. Admission behaviour here follows the documented SCC rules; what has been measured directly is the image under equivalent container constraints, and the rendered manifests.

`helm/agledger/values-openshift.yaml` sets the same flag for anyone who prefers a values file, but reaching it means `helm pull --untar` first, so `--set` is the shorter path from the OCI registry. `./scripts/helm-install.sh` detects OpenShift (via the `security.openshift.io` API group) and sets the flag for you unless you configured it yourself.

### External Database

The bundled PostgreSQL container is the default. To point at Aurora, RDS, Cloud SQL, or another managed Postgres, set `DATABASE_URL` in `compose/.env` and use `--external-db`:

```bash
./scripts/install.sh --external-db
```

Requirements:

- A connection pooler in front of the database is supported, with one extra setting. Set `DATABASE_URL_DIRECT` to a connection string that reaches PostgreSQL without a pooler in transaction mode, and leave `DATABASE_URL` pointing at the pooler. The transactional pool keeps running through the pooler and gets its connection multiplexing; the direct string carries only the work that needs a session that stays its own: the `LISTEN` client that keeps caches coherent across replicas, the session-level advisory locks that serialize the provisioning reconcile and the federation zero-row sweep, migrations, and the session settings that cap statement and idle-in-transaction time. Leave it unset for a direct database or a pooler in session mode, where everything runs on `DATABASE_URL` as before.
- The API and Worker refuse to boot when `DATABASE_URL` is behind a transaction-mode pooler and `DATABASE_URL_DIRECT` is unset, and the refusal names the setting. What they detect is the topology itself, not the hostname: two connections that report one backend process, or one advisory lock granted to both of them. Neither is possible on a direct connection, so the check cannot refuse a topology that would have worked. A pooler in session mode passes, because it pins one backend per client for that client's whole life. `preflight` reports the same reading under its `topology` check, and the Compose installer and the chart's preflight Job both run it before anything starts.
- What breaks without the direct string, measured through PgBouncer 1.25.2 with `pool_mode = transaction`: a `NOTIFY` sent from one connection is never delivered to a `LISTEN` on another, so every replica falls back to cache TTL expiry; `pg_try_advisory_lock` on the same key returns true to two different clients at once, so nothing that relies on one holder is serialized; and a session `SET` lands on whichever backend served it and stays there, visible to unrelated clients afterwards, because PgBouncer runs no `server_reset_query` in transaction mode unless `server_reset_query_always` is on. None of the three raises an error. `pnpm verify:pooler` in the API repo is the repeatable proof: it starts PgBouncer in transaction mode, runs migrations, records, webhook delivery, a maintenance tick, a vault scan, a provisioning reload and cross-replica cache invalidation through it, and asserts the refusal.
- **RDS Proxy**, read from AWS's *Avoiding pinning an RDS Proxy* page and not run here: it multiplexes at transaction granularity, and where a session surface would break it pins the connection to that client for the rest of the session instead. The conditions it lists for PostgreSQL include `SET` commands, `PREPARE`/`DISCARD`/`DEALLOCATE`/`EXECUTE`, temporary sequences, tables and views, declaring cursors, listening on a notification channel, and `pg_advisory_lock` / `pg_try_advisory_lock`. It states that transaction-level advisory locks (`pg_advisory_xact_lock` and its siblings) do not pin. So the session surfaces are correct behind the proxy, and the price is that the connections carrying them stop being shared. Point `DATABASE_URL_DIRECT` at the instance or cluster endpoint and leave `DATABASE_URL` on the proxy endpoint.
- One more thing to size on RDS Proxy: every connection this Server opens issues `SET idle_in_transaction_session_timeout` before it is handed to a caller, and `SET` is on that pinning list, so the transactional pool pins too and the proxy multiplexes nothing. AWS's documented way out is the proxy's initialization query, which applies the same settings at connection setup without pinning. Move `idle_in_transaction_session_timeout` (and `statement_timeout`, if `DATABASE_STATEMENT_TIMEOUT_MS` is set) there, and size `DATABASE_POOL_MAX` against the proxy's connection ceiling either way.
- pg-boss needs nothing from the direct string. Its only lock is `pg_advisory_xact_lock` inside one `BEGIN ... COMMIT`, its timeouts are `SET LOCAL`, and it issues no `LISTEN` under this Server's configuration.
- External databases are the Enterprise-contract case. See Licensing.
- The migration user needs schema-creation privileges. See `compose/.env.example`.
- The runtime user (`DATABASE_URL`) needs DML plus `CREATE` on the database. Migrations grant DML to the role named `agledger_app` specifically, so a non-owner role called anything else receives nothing; make yours a member instead, with `GRANT agledger_app TO "your_role" WITH INHERIT TRUE`. The `CREATE` grant is what pg-boss uses to install its own schema on first start, and can be revoked once the Server has booted successfully.
- `agledger_app` itself is not a credential you can connect with as it stands. The baseline creates it with a placeholder password that is a literal in a shipped SQL file, and every migration run takes `LOGIN` away from any role still accepting that password, so it cannot be used as a way into your chain. Put it into service with a password of your own before pointing `DATABASE_URL` at it:

  ```sql
  ALTER ROLE agledger_app LOGIN PASSWORD '<generated>';
  ```

  Or set `AGLEDGER_APP_ROLE_PASSWORD` where the migration runs (`compose/.env`; on the chart, `migrate.extraEnv` or a key of that name in `secrets.existingSecret`), and every migration run gives `agledger_app` its login under that password, `CREATE` on the database and ownership of the pg-boss schema. The bundled-Postgres installs (Compose and the chart) work this way out of the box: the migration runs as the owner and the API and worker connect as `agledger_app`, because an owner passes every privilege check on its own tables and would leave the append-only revokes on the audit chain binding nothing. Preflight warns on any runtime role that owns those tables. `agledger_app` is cluster-wide, so on a cluster serving more than one Server, set `AGLEDGER_APP_ROLE_PASSWORD` for at most one of them. **Upgrading an install whose `DATABASE_URL` carries the placeholder:** the first migration after upgrading closes it, and the Server then cannot connect. Run the `ALTER ROLE` above as a superuser (or the database owner), put the new password in `DATABASE_URL`, and restart.
- Set `DATABASE_POOL_MAX` to match your database's connection limits.

Both installers check that runtime role after migrating and before anything starts serving, so a role that cannot serve stops the install with the missing grant named instead of leaving crash-looping workloads behind a success message. On Compose the check is a step in `install.sh`. On the chart it is a `pre-install`/`pre-upgrade` hook Job, so `helm install` exits non-zero and creates no workload; migrations have run by then, and so have the release's ConfigMap and Secret, which are hook resources and outlive a `helm uninstall`, but the API and Worker are still unmade. Read the hook's report with:

```bash
kubectl logs -n <namespace> --tail=-1 \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=preflight
```

`scripts/helm-install.sh` prints it for you. Apply what it asks for and run the installer again: a failed release keeps its name, and the re-run reconciles it in place rather than refusing the name, so nothing needs uninstalling first. It reads the version off the release's own revisions, including a first install that never reached `deployed`, so a plain re-run stays on the version that install named.

`restore.sh` asks it too, after the restore and before it starts anything. A restore rebuilds the database the runtime role's access rests on, so it is the same question at a different moment: your rows are back, and the check answers whether the role can read them. Stopping there leaves the data restored and the API and Worker still stopped, rather than a stack coming up unhealthy with nothing naming the reason. Stopping there still prints everything the run has to tell you about the database now on disk, including that `api_keys` came from the backup and which keys that invalidates, so the grant you run and the credential you use are both in front of you.

`restore.sh` also asks the migration question, and asks it first, before it stops anything or drops the database. The schema carries the `agledger_block_audit_drop` event trigger, `CREATE EVENT TRIGGER` is superuser-only, and `pg_restore` does not stop when it is refused: it reports the refusal among its own "errors ignored on restore", puts every row back and exits 1. That is the one failure that costs you something, because the database it would go back to was dropped at the top of the run. Asked first, the refusal is free, and it prints the same provider grants `install.sh` does. This matters more on a restore than on an install: DR routinely runs against a rebuilt server whose roles were recreated by whatever provisioning ran, which is exactly how the grant goes missing.

The gate asks whether the role holds a superuser-equivalent role, which is not quite the same question as whether the server will accept the statement. So `restore.sh` also checks, after the restore, that the trigger is actually there, and if it is not it names what is missing and prints the single `CREATE EVENT TRIGGER` statement that repairs it. Your rows and the signature chain are unaffected either way: what the trigger provides is layer 2 of the tamper model, the DDL guard that refuses a `DROP` of `audit_vault`, its partitions, `vault_checkpoints`, `vault_signing_keys`, `scitt_entries` and the `org_admin_read*` tables unless the session has declared `agledger.allow_audit_drop`, the documented partition-archival path. The row-level DML triggers, the signed checkpoints and the external anchors are all independent of it.

`upgrade.sh` asks the same question twice, because the grant can lapse between installs: a role dropped and recreated by a rotation policy comes back without its `agledger_app` membership. The first check runs before the pre-upgrade backup, which is otherwise the first thing to fail, as `pg_dump` reporting a table it was refused and printing its whole `LOCK TABLE` statement without naming the role. Stopping there costs nothing: no backup, no migration, and `.env` still names the version you are on. The second runs after migrations, for the tables a new migration just added, and reports what stopping at that point means: the migrations are applied, the worker is stopped until the upgrade finishes, and re-running after fixing the grant completes it.

### Air-Gapped / Restricted-Network Installs

`install.sh --image` lets you point at an internal registry. See [air-gap/README.md](air-gap/README.md) for the full flow.

### FIPS 140 hosts (ES256 signing)

AGLedger signs its chain with Ed25519 by default. A host running OpenSSL in FIPS mode cannot compute Ed25519: the provider does not carry it, and signing fails with `error:0308010C:digital envelope routines::unsupported`. For those hosts AGLedger supports a **single-Server ES256 configuration**, where every signature (chain, receipts, webhooks) uses ECDSA P-256 with SHA-256 instead.

Install with FIPS from the start:

```bash
./scripts/install.sh --fips
```

`--fips` implies ES256: it generates a P-256 vault key and writes `AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true`, the explicit acknowledgment the Server requires before it will boot on a non-default algorithm. It also records `AGLEDGER_FIPS=true` in `compose/.env`, which adds the shipped `compose/docker-compose.fips.yml` overlay to every compose command the scripts run afterwards, `upgrade.sh` included.

The overlay mounts `compose/openssl-fips.cnf` and points `OPENSSL_CONF` at it. The provider ships in the runtime image and activates from that config alone: no FIPS kernel, no `openssl fipsinstall` step.

The flag is sticky on purpose. An upgrade that recreated the containers without the overlay would leave the host running non-FIPS with nothing to notice it, because an ES256 key signs perfectly well with or without the provider active.

`--fips` against an install that already holds an Ed25519 key is refused, with the rotation steps below: the provider carries no EdDSA, so that Server would boot unable to sign at all.

**What you give up.** This is a deliberately narrow configuration, and the Server enforces its edges rather than degrading quietly:

- **Federation is not available.** The federation transport signs with Ed25519 by design. A Server configured with both ES256 and federation keys refuses to boot, naming the conflict, rather than starting with a transport it cannot sign for.
- **Ed25519-pinned surfaces refuse explicitly.** A webhook subscription requesting `signingAlg: "ed25519"` returns 422 naming the algorithms this Server can use (`ecdsa-p256-sha256`, `hmac`). Nothing silently downgrades.
- **Consumers need a current verifier.** Anyone verifying your chain offline needs `@agledger/verify` 2.0.0 or later, the floor for every 2.x install whatever its algorithm; that release carries ES256. Your Server publishes the floor per key as `minVerifierVersion` at `GET /v1/verification-keys`.

**Licensing note.** Ed25519 is itself FIPS-approved (FIPS 186-5), and validated modules that implement it exist. The exclusion here is the vintage of the FIPS provider shipped with the runtime base image, not a property of the algorithm.

**Switching an install that already has a chain.** Do not reinstall: entries already written must keep verifying. Rotate instead.

```bash
# 1. generate a P-256 key
docker run --rm agledger/agledger:<version> dist/scripts/generate-signing-key.js --algorithm es256

# 2. in compose/.env, move the current VAULT_SIGNING_KEY to VAULT_SIGNING_KEY_PREVIOUS,
#    then set the new VAULT_SIGNING_KEY and AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true

# 3. restart every process. The first one up registers the new key and writes a
#    succession statement signed by both keys; nothing is retired.
docker compose up -d --force-recreate

# 4. both keys are active now. Read which ones still have a process behind them;
#    the new key must report trust "anchored".
curl -s -H "Authorization: Bearer $PLATFORM_API_KEY" \
  http://localhost:3001/v1/admin/vault/signing-keys \
  | jq '.data[] | {keyId, algorithm, status, trust, activatedAt, retiredAt, lastSignedAt}'

# 5. once the old key has signed nothing for 300 seconds, close its window from a
#    process on the new key. Until you do this it stays active, which costs nothing.
curl -s -X POST -H "Authorization: Bearer $PLATFORM_API_KEY" \
  http://localhost:3001/v1/admin/vault/signing-keys/<old-key-id>/retire | jq .

# 6. remove VAULT_SIGNING_KEY_PREVIOUS from compose/.env.
```

## Changing the signing key

A key change is two steps, and they are separate on purpose.

**Trust.** A key in `vault_signing_keys` is trusted only when a signed key statement (table `vault_key_statements`) links it to a key some process holds outside the database: the key it signs with (`VAULT_SIGNING_KEY`, or the KMS key at `VAULT_SIGNING_KEY_KMS_ARN`), its predecessor signer (`VAULT_SIGNING_KEY_PREVIOUS`, or `VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN`), or a pin in `VAULT_TRUST_ANCHORS` (comma list of `sha256:<64 hex>`, the SHA-256 of a key's SPKI DER). The database stores statements and vouches for none of them. A key row written with database access alone (a leaked `DATABASE_URL`, say) verifies nothing: entries it signs break as `signing_key_unanchored`, it is absent from `GET /v1/verification-keys`, `/.well-known/agledger-vault-keys.json`, `/.well-known/scitt-keys` and the audit export's `signingKeyWindows`, and an ephemeral-certificate JWS naming it gets 401. It shows only on the authenticated `GET /v1/admin/vault/signing-keys`, as `trust: "unanchored"`; every key there carries `trust` and `admittedBy`.

**Pins.** The installer prints the new key's pin (`Pin: sha256:<hex>`). `node dist/scripts/signing-key-digest.js` derives the same value from `VAULT_SIGNING_KEY` or `VAULT_SIGNING_KEY_FILE`, from `--kms-arn <arn>`, or from `--public-key <base64 SPKI|->` (pipe in `aws kms get-public-key --key-id <arn> --query PublicKey --output text`). Give an auditor the pin of any one key of the install: trust runs through successions, so a pin taken at install time keeps anchoring every later key a routine retirement leads to. A forced retirement voids what the retired key admitted and the history behind it, and after one auditors take a new pin plus the pins of the history you re-anchor (the response's `nextSteps` say so). `GET /v1/verification-keys` publishes `anchoredFrom` (the serving process's key pin) and per-key `statements`; `anchoredFrom` is something to compare against the pin, never a replacement for it.

**Staging** is a restart. Start one process on the new `VAULT_SIGNING_KEY` with `VAULT_SIGNING_KEY_PREVIOUS` set to the key the running processes sign with. On boot it registers the new key, activates it and writes a succession statement signed by both keys; the `KEY_ROTATED` chain entry names the statement digests. Once that succession exists, other processes on the new key need no `VAULT_SIGNING_KEY_PREVIOUS` (on Helm every pod receives `secrets.vaultSigningKeyPrevious`, which is harmless; remove it after the old key is retired). A process on a new key with no predecessor signer, against a registry that already holds keys, registers nothing and signs nothing: `/health` reports `signingKey.gate: "unanchored"`, `/health/ready` answers 503, a worker stops consuming jobs (`jobConsumption: "stopped_signing_key_unanchored"`), and the rotate endpoint answers 409 with a `recoveryHint`. Staging retires nothing, so **more than one key is active while you roll**, and every process you have not restarted yet keeps signing inside its own key's published window. Nothing it writes fails verification. `POST /v1/admin/vault/signing-keys/rotate` performs the same registration on demand and answers `already_active` once the restart has done it; its `nextSteps` walk the rest of this procedure.

**Retirement** closes a key's window and is an explicit call: `POST /v1/admin/vault/signing-keys/{keyId}/retire`, sent to a process holding a different active, anchored key (normally one on the new key); a process on the key being retired answers 409 and says what to do. It stamps `retiredAt` and writes a closure statement, signed by the calling process's key, over that `retiredAt`. Anything the retired key admits after the closure counts for nothing, which bounds a key whose private half leaks after a routine retirement. The response carries `closureDigest` and `unanchoredKeyIds`. After it, an entry written under that key is a chain break, reported as `key_expired` by the Server and as `CHAIN_KEY_EXPIRED` by `@agledger/verify`. Entries written before it stay valid forever.

Both steps are the same for a key held in AWS KMS (`VAULT_SIGNING_KEY_KMS_ARN`; `signing.kmsKeyArn` on Helm), and the process registers the key under the fingerprint of the public half it fetches from KMS. Moving from a local key to KMS: set the ARN, move the local key to `VAULT_SIGNING_KEY_PREVIOUS`, unset `VAULT_SIGNING_KEY` (the two together refuse to boot), restart, then retire the local key id. Moving from one KMS key to another: set the new ARN and `VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN` (`signing.previousKmsKeyArn` on Helm) to the old one, and give the process `kms:GetPublicKey` and `kms:Sign` on both keys for the change; the old key never leaves KMS and signs only the succession. `VAULT_SIGNING_KEY_PREVIOUS` and `VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN` together refuse to boot. `deploy/SECURITY.md` describes what custody changes and what happens when KMS does not answer.

### Rotating on a running install (HA order)

Any install with more than one process is HA for this purpose, and **a single-replica Helm install counts**: the api and the worker are separate Deployments and both sign.

1. Generate the new key and put it where every process reads it, with the key they sign with now as `VAULT_SIGNING_KEY_PREVIOUS`. On Helm, `vaultSigningKey` and `vaultSigningKeyPrevious` in values (or your own Secret).
2. Restart or roll every api and worker process. On Helm, a chart-managed Secret change rolls both Deployments by itself; with `existingSecret` set, nothing watches the Secret and **you restart both Deployments yourself** (`kubectl rollout restart deploy -n <ns> -l app.kubernetes.io/instance=<release>`, which restarts both without depending on the rendered names).
3. Probe `GET /health` on every api and worker process, not through the load balancer, and check that each one reports `signingKey.keyId` as the new key. This is the check that proves no process still holds the old key: a process you missed reports the old key id here and nowhere else.
4. Cross-check the chain: `GET /v1/admin/vault/signing-keys` reports `lastSignedAt` per key over the last 300 seconds. A recent value under the old key proves a process is still signing with it. A null does not prove the opposite: an idle install, or a process whose only use of the key is webhook deliveries, certificates or Receipts, appends nothing and leaves it null while still holding the key. That is why step 3 comes first.
5. `POST /v1/admin/vault/signing-keys/{oldKeyId}/retire`, against a process on the new key. While the old key has appended inside the last 300 seconds it refuses with 422 and names the key, rather than let a process you forgot write entries that can never be repaired. That refusal is a backstop for the case the chain can see, not a substitute for step 3.
6. Remove `VAULT_SIGNING_KEY_PREVIOUS` (`vaultSigningKeyPrevious`) and roll again at your convenience.

Skipping step 3 is the failure this order exists to prevent. Everything a process writes after its key's `retiredAt` fails offline verification permanently: the chain is append-only, so those entries cannot be re-signed or removed.

Leaving the old key active is not an error state. It costs nothing but an extra published key, and until you retire it every process signing with it is writing valid entries.

### Rotating a key that leaked (compromise order)

Same two steps, without the wait.

1. Generate the new key, put it where every process reads it with the leaked key as `VAULT_SIGNING_KEY_PREVIOUS`, and restart them.
2. `POST /v1/admin/vault/signing-keys/{oldKeyId}/retire` with `{"force": true}`, immediately, from a process on the new key. This is what `force` is for: a key whose private half is out must stop being honoured now. It skips the quiet period and revokes the key's unexpired ephemeral certificates.

The closure a forced retirement writes is forced: it voids every edge out of the leaked key, whenever it signed it, so every key it admitted loses that path, and so does the history behind it, which was reached back through the predecessor the leaked key named. The Server walks the key registry again with the closure in place, and every key it no longer reaches is listed in `unanchoredKeyIds`: its row is retired in the same transaction, its certificates are revoked, and entries it signed break as `signing_key_unanchored`. Entries the leaked key itself signed before the retirement still verify. A key in that list that you know is honest is trusted again only from outside the database: add its pin to `VAULT_TRUST_ANCHORS` on every process and restart, then, where the scan reports `key_closure_invalid` for it, call the retire endpoint for it without `force`, which signs the retirement its row already carries; a key whose retirement a closure already signs needs only the pin. Until it is pinned, the scan reports the statements that admit it as `key_statement_invalid`. A process that signed with such a key restarts on a fresh key staged from a process on an anchored one. An auditor whose pin reached the current keys only through the leaked key no longer reaches them, and one pinned on a current key no longer reaches the history behind the leaked key; give each one the pin of the key that retired it plus every pin you added to `VAULT_TRUST_ANCHORS`.

A key found leaked after it was retired on schedule is retired again with `{"force": true}`. Its `retiredAt` does not move; the call writes a forced closure, with the same effect, and revokes its certificates. On a key a forced closure already closes, it writes no second closure. `alreadyRetired` is `true` in the response.

A leaked key can still sign closures of other keys, and they apply until you distrust it: a closure only takes trust away, so the worst it does is shorten a key's window or void what that key admits, and nothing it signs makes a key trusted that was not. But that worst is real, and nothing inside the database undoes it: a closure it signs after the forced retirement, dated before your current key was activated, ends that key's window at the date it names, so every entry the current key signed reads as `key_expired` and its certificates stop authenticating. The same holds for a key retired on schedule whose private half leaks later. Set `VAULT_DISTRUSTED_KEYS` to its pin on every process and restart (the retire response carries it as `retiredSpkiSha256`, and its `nextSteps` spell out the entry): what the key signs from its retirement on then counts for nothing, what it signed before keeps counting, so its honest closure of its own predecessor still holds, and the scan reports each statement it signed since as counting for nothing. Add `@<RFC 3339 instant>` to the entry when the key leaked before it was retired, so what it signed from the leak counts for nothing too; a key with no instant and no retirement is trusted for nothing. List every key that leaked: a closure the listed key signed from its instant no longer counts, honest ones included, so a key it retired after that instant is open again unless another key retired it, and the scan's finding for that closure names the key to add. A closure that counts though its signer stored it after its own retirement, or that dates a retirement before its subject's activation, is reported as `key_closure_invalid` with the entry in its detail. Give auditors the same entry and the instant with the pin: `@agledger/verify` 2.0.0 or later takes them as `--distrusted-key` and `--trust-anchor`, on an audit export and on a vault dump alike. A dump carries no distrust entry, so an auditor who leaves it out passes on a dump the entries the instant took away. A process refuses to boot when the list names its own key or its predecessor, or names a `VAULT_TRUST_ANCHORS` pin with no instant; a pin beside a dated entry vouches for what the key signed before the instant.

If there is no successor you trust, or `VAULT_SIGNING_KEY_PREVIOUS` is lost: set `VAULT_TRUST_ANCHORS` to the pins of the keys whose history you vouch for and restart. A process whose key nothing links to that history then registers under a fresh genesis, and you give auditors the new key's pin. Nothing inside the database can tell your successor from an attacker's; an authority held outside it, the pin, is the only thing that does.

Chain appends under that key stop the instant the retirement commits: the retirement and the appends in flight take the same row lock, so no entry is written carrying a time after the retirement instant. The other signers stop when the process notices the retirement: at once on api and worker processes alike, which both hold the LISTEN connection the retirement is broadcast on, and otherwise within 30 seconds, the interval at which each process re-reads the registry in case a broadcast was missed. Until then a process that has not been restarted can still sign RFC 9421 webhook deliveries, ephemeral-certificate JWS and Receipts under the retired key; a receiver holding those against the published window rejects them, which is the intended outcome for a leaked key. A process that has noticed refuses `/health/ready` with `signingKey.gate: "retired"`, leaves the load balancer's rotation, and on the worker stops consuming jobs (`/health` reports `jobConsumption: "stopped_signing_key_retired"`) so queued work waits for a worker running the new key. Restart each one. Anything an attacker signs with the leaked key afterwards falls outside its published window and is reported as `key_expired` by a chain scan and as `CHAIN_KEY_EXPIRED` by an offline verifier.

Retiring the only active key is always refused: it would leave nothing able to sign. Stage the replacement first.

Finish a key change before a version upgrade starts, and do not start one during a rollout.

### What retirement does not do

Retirement closes a window; it does not delete a key. `GET /v1/verification-keys` keeps serving every historical anchored public key with the exact instants it was active (`activatedAt` / `retiredAt`, the values the key statements sign), which is what lets a verifier check each entry against the key that actually signed it. Entries written inside a key's published window keep verifying under it after retirement. No re-signing, and the chain stays continuous.

There is no `compromised` status and no revocation of what a key signed. A retired key keeps verifying the entries it signed inside its published window (a distrust instant ends that window early, and a forced retirement's `unanchoredKeyIds` stop verifying until pinned), which is correct for a routine rotation and means the Server will not flag records signed while a key was out. Rotation stops future signing with that key; it says nothing about what was signed before it. External anchors are what bound that span. [Signing-key compromise](https://agledger.ai/docs/operations/key-compromise) is the runbook.

Re-running `install.sh` with `AGLEDGER_SIGNING_ALGORITHM` set does **not** change the algorithm of an existing install. The signing key is generated only alongside the other secrets, so a run that finds an existing `.env` keeps the key it already has; the installer says so rather than reporting a success that did not happen.

**Verifying FIPS is actually on.** Ask the running container:

```bash
docker compose exec -e NODE_OPTIONS= agledger-api /nodejs/bin/node -e "console.log(require('crypto').getFips())"   # 1 when active
```

With the provider active and an ES256 key, the install runs normally: records notarize, gates evaluate, and a chain scan (`POST /v1/admin/vault/scan`, then poll the returned job at `GET /v1/admin/vault/scan/{jobId}`) reports the chain healthy. Every release blocks on a boot gate that runs this exact configuration on linux/amd64, asserting both that the ES256 serve path works and that a federation-configured Server refuses to start under it; the arm64 image is built from the same sources and is not run under the provider by the gate.

### Federation (link multiple Servers)

AGLedger has a single role: Server. To federate, run more than one Server (each a full, independent install with its own database and signing key) and link them so chains can reference records across Servers. There is no hub, gateway, or central coordinator: peers exchange public keys out of band and handshake directly via `POST /federation/v1/peer`. Configure it by setting the `AGLEDGER_FEDERATION_*` keys in `compose/.env`; generate them with `./scripts/generate-federation-keys.sh` (see `compose/.env.example`). On Kubernetes there is no checkout to run that from, so generate the key in the pod: `kubectl exec -n <ns> "$(kubectl get deploy -n <ns> -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=api -o name | head -1)" -- env NODE_OPTIONS= /nodejs/bin/node dist/scripts/generate-federation-keys.js --stdout`. Use `--stdout` in any container: the image runs with a read-only root filesystem, and that mode writes nothing to disk. The chart-managed Secret carries only the engine's own keys and a `helm upgrade` re-renders it, so keep the federation key in a Secret you manage and reference it from `extraEnv` with a `secretKeyRef` (see the `extraEnv` block in values.yaml). Full setup is at [agledger.ai/docs](https://agledger.ai/docs).

## Remote deploy (`agl-deploy.sh`)

`scripts/agl-deploy.sh` is a client-side wrapper that deploys and operates a Server on a remote host over SSH. It runs from your machine, opens one SSH connection per operation, and drives the same signed installer and on-target scripts described above. It never reimplements image verification, key minting, or migrations.

```bash
# deploy to a fresh host: installs prerequisites, verifies the image, mints the platform key
./scripts/agl-deploy.sh -H user@host -i ~/.ssh/key install

# day-2: status / health / logs / reprint key / upgrade
./scripts/agl-deploy.sh -H user@host -i ~/.ssh/key status

# the Compose API is loopback-only on the remote, so reach it over an SSH tunnel
./scripts/agl-deploy.sh -H user@host -i ~/.ssh/key tunnel    # then: curl http://localhost:3001/health

# reach a host you can't route to directly (bridge-private container) via a bastion
./scripts/agl-deploy.sh -H user@10.0.0.5 -J you@bastion -i ~/.ssh/key tunnel
```

Commands: `bootstrap install upgrade status health key logs tunnel shell uninstall [--purge]`. Flags can be set as `AGL_*` environment variables to pin a host once. It deploys the Compose stack on Docker CE with bundled PostgreSQL, the substrate the free Developer Edition grant covers for production; install a key to license it, and for production also set `AGLEDGER_EXTERNAL_URL` and front the API with TLS. For multi-node scale, HA, or an external database, see the [Helm chart](#kubernetes-helm). The chart runs on the same bundled PostgreSQL that grant covers; only pointing it at an external database requires Enterprise. Run `./scripts/agl-deploy.sh --help` for the full reference.

## Upgrading

Refresh the install scripts first, then upgrade:

```bash
git pull
./scripts/upgrade.sh <version>
```

`upgrade.sh` never updates itself, only the image, and a release's `.env` reconcile steps ship in the new script: minting the `METRICS_AUTH_TOKEN` that the production default for `/metrics` requires, when `.env` has none, is one of them. Running an older copy skips them. If you already upgraded with one, `git pull` and re-run `upgrade.sh` against the version you are on: it reconciles `.env`, prints the `docker compose up -d` that makes the repairs live, and stops without pulling, backing up or restarting anything. `restore.sh` performs the same reconcile before it starts the stack, so a DR restore onto a host whose `compose/.env` lacks those repairs does not bring up a Server missing them.

"Already on that version" means the stack is serving it. If `.env` names the target and the API is not answering `/health`, the run treats it as an interrupted upgrade rather than a no-op: it re-attempts the restart and leaves the rollback marker holding the version the first attempt recorded.

"Serving" throughout means the API answers `/health/ready`, the endpoint that runs a query, not the static 200 at `/health`. A Server pointed at a database that is down, gone or refusing its credentials answers the second one.

The upgrade script creates a backup before upgrading, and writes `backup/.pre-upgrade-version-<compose project>` naming what to roll back to. That marker is written even under `--skip-backup`, and even on a host with no `backup/` directory yet. Rollback is `./scripts/restore.sh <backup>`: each archive records the version it was taken from, and the restore returns the install to that version, because the dump and the schema have to agree. It fetches that image before it drops anything and refuses with the database untouched if it cannot, naming both ways forward. Where it does not move the version at all (an archive too old to carry the record, or `--keep-version`), the run says in one line which version is actually serving, and where it knows which version to return to, the command that gets there.

On an external database, `restore.sh` restores into the database `DATABASE_URL` names, and drops and recreates that one. `POSTGRES_DB` configures the bundled PostgreSQL container and has no bearing on an external install. Before dropping, it checks the database looks like an AGLedger one (a `public.records` table); on a shared managed instance, where a database of the same name may belong to something else, that check is what stands between a restore and an unrecoverable drop. Pass `--force` to restore into a database that does not have the table yet.

The dump's privileges are restored with it: the DML grants, the `ALTER DEFAULT PRIVILEGES`, and the append-only `REVOKE`s on the audit chain, so a least-privilege role comes back able to serve. Restoring onto a server that does not carry the same roles (a cross-server DR) reports the grants it could not apply and continues; the runtime-role check that follows decides whether the Server starts.

### Two releases against one schema

Every upgrade path migrates the database before the new processes exist. On Kubernetes the migration is a `pre-install,pre-upgrade` hook Job, so it finishes while the pods of the release you are leaving are still serving. On Compose `upgrade.sh` stops the worker first and migrates with the old API still up, then recreates the containers. From the moment the migration commits until the last process of the old release is gone, two releases read and write one schema.

The chart ships `strategy.type: Recreate` for both the API and the worker, which holds that window to the gap between the old pods stopping and the new ones passing their probes. Setting `api.strategy.type` or `worker.strategy.type` to `RollingUpdate`, which is what a multi-node install wants, stretches it across the whole rollout: pods of both releases answer the same Service, behind the same load balancer, at the same time. Two things follow from that, and only the second needs anything from you.

**Within a major version, the schema is safe in both directions.** A release removes or tightens nothing the release before it in the same major reads or writes; a removal waits for the release after. The engine's own release gate runs the previous release's database suite against the new schema before a version is tagged, so the mixed window needs no ordering and no maintenance mode. A new major does not keep this: its migrations remove what the previous major reads and writes, so no process of the previous major may serve once the migration has run, and going back means restoring the backup taken before the upgrade.

**A security control a release introduces is in force only once no process of the previous release remains.** Such a control is checked by the processes carrying that release and by no other, so applying a restriction mid-rollout applies it on some of the pods answering the load balancer and not the rest. `GET /v1/admin/system-health` answers the question: `connectedVersions` lists every AGLedger version holding a connection on the database, each with how many connections and when the oldest of them was opened, and the control binds every request once that list holds one entry. `connectedVersions: null` means the view could not be read, which is not the same as nothing being connected.

**2.0 does not upgrade a 1.x database.** The migration refuses a database a 1.x release migrated before it changes anything, and says so: the checksum it recorded for `001_consolidated.sql` is not the one 2.0 ships. Install 2.0 against a new, empty database, and keep the 1.x database for the 1.x install that wrote it. A backup does not carry 1.x data across either: `restore.sh` returns the install to the release the backup was taken on, `--keep-version` with a 1.x archive is refused before anything is stopped or dropped, and an archive that records no version reaches the 2.0 migration, which refuses the restored database the same way. `upgrade.sh` refuses an install whose recorded or running version is 1.x at its version check, before it writes `.env`, takes a backup or stops anything. Put the checkout back on the 1.x `deploy/` tree afterwards: a `docker compose` command run from the 2.0 tree starts 2.0 against the 1.x database. When the version was not recorded and the migration is what refuses, the recovery text names that tree rather than a re-run. On Helm with the bundled PostgreSQL, a 2.0 chart refuses to render over a release a 1.x chart installed, so `helm upgrade` fails before anything is replaced; that check reads the release through `lookup`, which answers nothing under a renderer such as Argo CD.

**A migration can run out of lock budget under sustained writes.** A migration that cannot take a table's lock within `MIGRATION_LOCK_TIMEOUT` (default `30s`) rolls back whole with `lock_not_available`. On Compose the migrate CLI exits 75 for this failure alone and `upgrade.sh` retries it, three attempts in all, with the previous API serving throughout. On Kubernetes the migrate Job retries up to its `backoffLimit`; on an external database it is a pre-upgrade hook, so the previous release keeps serving, but on bundled PostgreSQL it is an ordinary resource and the new pods start without waiting for it, crashlooping until a migration lands. If it still fails, set `MIGRATION_LOCK_TIMEOUT=120s` (`compose/.env`, or `migrate.extraEnv` on the chart) and re-run, or upgrade in a low-traffic window. On the chart, size `helm upgrade --timeout` (default 5m) to cover every Job attempt: about four times the lock budget plus the migration's own run time, or Helm reports the hook failed while a later attempt is still running.

**Rolling back within a major takes the processes back, not the schema.** `helm rollback` runs no migrate Job, because the migration is a `pre-install,pre-upgrade` hook and rollback triggers neither; the older image comes up against the newer schema, which is the same mixed case as the upgrade and is safe for the same reason. On Compose, `restore.sh` does move the schema, because a dump and the schema it came from have to agree. What does not resolve itself either way is work the newer release scheduled: a worker on the older release carries no handler for a sweep the newer one added, so it fails those jobs rather than completing them, counts them on `agledger_maintenance_unknown_task_total`, and the pg-boss cron keeps minting them from the schedule the newer release wrote. Going forward again clears it.

## Backups and point-in-time recovery

### Docker Compose

```bash
./scripts/backup.sh                          # keep the last 7
./scripts/backup.sh --keep 30
BACKUP_DIR=/mnt/backups ./scripts/backup.sh
```

Archives go to `backup/` inside this checkout unless `BACKUP_DIR` names somewhere else, which is what a
mounted backup volume wants. `upgrade.sh` writes its pre-upgrade archive and the rollback marker to
the same place, so a checkout carries its own rollback material. Each archive is named
`backup-<compose project>-<timestamp>.tar.gz` and `--keep` only counts and removes archives carrying
this install's project name: several installs can share one `BACKUP_DIR` without one install's
retention reaching another's files.

Restoring is `./scripts/restore.sh <archive>`. Each archive `backup.sh` writes records the version it
was taken from, so the restore returns the install to that version before starting it. An archive
that carries no such record (one the chart's backup Job wrote) leaves
the install where it is, and the run says so. It fetches that image before it
drops anything, and refuses with the database untouched if it cannot. Two flags change what it does:
`--force` restores into a database that does not carry the `public.records` table yet, and
`--keep-version` restores the data onto the release the install is on now, which re-applies that
release's migrations over the older dump.

The migration and the checks around it run in the image of the release the install runs, which is
`AGLEDGER_VERSION` in `compose/.env`. A host restoring into a cluster has no `compose/.env`, so it
names the release with `--version` (or `AGLEDGER_VERSION` in the environment); with none named, or
`latest`, the restore refuses before it stops anything rather than migrate with whatever Docker Hub
published last. On an external database with a separate runtime role, pass `DATABASE_URL` as that
role and `DATABASE_URL_MIGRATE` as the owner: given one URL, the restore hands the `pgboss` schema to
that URL's role, so it refuses one URL when the database it replaces keeps `pgboss` under another.
A migration that fails ends the run with exit 1 and nothing started. The recovery runbook carries
the Kubernetes recipe.

`--keep` is a count of archives to retain and has a floor of 1: the run keeps the backup it just
took, so 0 is not a retention policy and is refused rather than honoured. To remove backups, delete
them from the backup directory.

Each run writes one timestamped tarball holding a `pg_dump` custom-format dump of the whole database
(`db.dump`) and a CSV export of the signing-key registry's **public** keys. Private signing keys are
never in the database and never in a backup. Webhook signing secrets are: `webhook_subscriptions.secret`
and `previous_secret` are AES-256-GCM ciphertext under `WEBHOOK_ENCRYPTION_KEY` (or `API_KEY_SECRET`
when that is unset), so a backup together with `.env` decrypts every subscription's secret. Neither is `compose/.env`, which holds `VAULT_SIGNING_KEY`
and `API_KEY_SECRET` (and the federation key, if you added one): back it up
separately, under the controls you apply to the keys themselves. A restore onto a host with a
different `.env` signs new entries under a new key and fails every restored API key.

The anchor key prefix is not one of those hazards: the instance id lives in the database, in
`server_identity`, written on first boot and read on every boot after it. A restore onto a rebuilt
host keeps reaching the anchors the install already wrote, whatever the new `.env` says, because
`restore.sh` writes the restored database's id back into `compose/.env` before it starts anything.
Setting `AGLEDGER_INSTANCE_ID` to something an operator already chose refuses boot, naming both
values and both ways out, because the alternative is anchors silently split across two prefixes.
Setting it on an install that never had one is adopted with a warning instead, so re-running
`install.sh` (which mints the variable when `.env` has none) cannot stop a Server that was serving.
The chart does the same on Kubernetes: a first install generates a UUID into the release's ConfigMap,
every upgrade reads it back, and a release whose ConfigMap carries no id keeps `default`, the prefix
it has anchored under. The `instanceId` value pins it where the chart cannot read it back: a renderer
(`secrets.gitops`), `secrets.existingSecret` with no ConfigMap to read (both refuse the render until
it is set), or a release restored from another release's backup, whose post-restore Job prints the
database's id. A Server reads only its own prefix; `vault-anchors/default/` is where an install that
sets no id at all anchors. Before the script reports success it checks that
`db.dump` starts with the archive header `pg_restore` expects, so a dump that something else wrote
to is deleted and reported now rather than discovered during a restore, after `restore.sh` has
already dropped the database.

**What ships is snapshot backup, not continuous archiving.** Nothing in the Compose files, the chart
or the scripts sets `archive_mode` or an `archive_command`, and the bundled `postgres:18-alpine`
runs stock configuration. So your recovery point is the last snapshot: run `backup.sh` on the
cadence your RPO needs, and understand that everything notarized since it is not in any copy the
product holds.

Point-in-time recovery is a property of the database, and AGLedger neither provides nor prevents it:

- **Bundled PostgreSQL.** Configure continuous WAL archiving on that instance yourself, the same way
  you would for any PostgreSQL you own, and treat the archive as a second destination alongside the
  `backup.sh` tarballs rather than a replacement for them. The tarball is what `restore.sh` reads.
- **External or managed PostgreSQL** (Aurora, RDS, Cloud SQL, Azure). Use the provider's PITR. It is
  the shorter path to a sub-minute RPO, and `backup.sh` on an external `DATABASE_URL` runs `pg_dump`
  directly, so the two are independent of each other.

**Verify the chain after any restore, and after a PITR restore in particular.** A recovery to an
earlier point in time gives you a chain that ends earlier, and a chain truncated from the end still
hash-links cleanly, so the walk alone will not tell you entries are missing. `./scripts/vault-verify.sh`
runs the Server's own walk (hash links, positions, signatures, key windows, payload binding) against
the restored database and will report that chain healthy.

Only evidence held **outside** the database can tell you where the chain used to end. `vault_checkpoints`
cannot: it is an ordinary table in the same database, so a recovery to time T rolls the checkpoints
back with the chain, and the restored checkpoint agrees with the restored truncated chain. External
anchors are the exception, and the only one. With `VAULT_ANCHOR_ENABLED=true` each checkpoint is also
written to S3-compatible storage under COMPLIANCE-mode object lock, where the database recovery cannot
reach it.

### What the anchors detect, and what they do not

`restore.sh` runs three things against the restored database before it starts the Server, and the
Server repeats the last of them at boot and daily.

**Every restore leaves a marker.** `restore.sh` writes one row into `chain_restore_markers`, and the
next boot turns it into a signed `RESTORE_EPOCH` entry on the platform-ops chain plus a
`chain.restore_detected` row on the SIEM stream. This happens with no anchoring configured and with
nothing lost, so an offline reader of the chain and a SOC watching the stream can both tell where one
history stopped and another started. **The marker alone never stops writes**: a restore to the latest
backup with nothing lost must not strand the install.

**Anchor writes are create-only.** Every anchor PutObject carries `If-None-Match: *`. A second write
to a position this Server has already anchored is refused by the store, and the refusal is read back:
identical content is an idempotent replay, different content is a fork and is reported. This is the
check that catches a re-anchored position at the moment it happens rather than a day later.

**Anchor verification counts key versions.** `POST /v1/admin/vault/anchors/verify` reports a `fork`
outcome for any anchor key the store holds more than one version of, even when the latest version
matches the restored database perfectly, which is exactly what a rewind followed by fresh writes
looks like.

**A bucket-to-database comparison is its own call.** `POST /v1/admin/vault/anchors/reconcile` walks
this Server's anchor prefix (`vault-anchors/<instance id>/<record id>/<chain position>.json`) and
compares the highest anchored position per record against the database's chain head. `rewound` means the bucket holds a position past the database; `missing_locally`
means the bucket holds anchors for a record the database has nothing for. This is the check the verify
endpoint structurally cannot do: verify starts from the checkpoint rows the database still holds, and
a restore rolls those back, so a position the restore removed has no row to look its anchor up from.
The walk is bounded by a key cap and a time budget, whichever comes first, and a walk that stops on
either reports `truncated: true`, because a clean report over part of a bucket is not a clean report.

**Every anchor under this Server's prefix is evidence.** An anchor document that parses and agrees
with the key it was found at counts, whatever issuer its checkpoint names and whichever key signed
it. One that names an issuer other than this Server's current `AGLEDGER_EXTERNAL_URL` (compared as
URLs, so a trailing slash is not a difference) still refuses writes as a `rewound`,
`missing_locally` or `fork` finding, and the finding carries `signedForIssuer` with a message
naming both issuers: another Server may share `AGLEDGER_INSTANCE_ID`, or the external URL changed.
Both are worth stopping for. The way out is the acknowledgement below, or fixing the configuration.
The per-install instance id is what keeps two Servers sharing a bucket apart.

**A detected rewind stops chain writes.** Records, completions, verdicts, schema registrations and
SCITT registrations all answer `409` with `reason: CHAIN_REWIND_DETECTED` and a `recoveryHint` naming
`POST /v1/admin/vault/rewind/acknowledge`. `GET /v1/admin/vault/rewind` carries the evidence.
Acknowledging resumes writes and appends a second `RESTORE_EPOCH` entry carrying that evidence and
your note, so the two histories stay tellable apart. The signing-key registry's own entries are not
refused: a key the restored registry does not hold (one staged after the backup, or the fresh key a
compromise calls for) registers at boot, and the acknowledgement is signed under it. An
acknowledgement counts while its `RESTORE_EPOCH` verifies under a key the Server trusts, sits on an
intact link of the platform-ops chain, and is signed by a key no operator has retired with `force` or
listed in `VAULT_DISTRUSTED_KEYS`, and it covers only findings recorded at or before the detection it
signs, so a genuine acknowledgement copied back in after a later restore covers nothing found since. One that stops counting refuses writes again, and
`GET /v1/admin/vault/rewind` lists the findings it covered with the reason, until the next
acknowledgement covers them.

**What none of this detects:**

- **Anything written since the last checkpoint sweep.** Anchors exist per checkpoint, and checkpoints
  are written on the `VAULT_ANCHOR_INTERVAL_MINUTES` cadence. A restore that loses only entries
  written since the last sweep loses nothing any anchor points at, and every check above reports
  clean. That interval is your detection window, and shortening it is the only thing that narrows it.
- **An install with no anchoring configured.** Nothing outside the database says where its chain used
  to end. The restore marker still lands, so the chain and the SIEM stream record that a restore
  happened, but nothing can say whether anything was lost. Reconcile against your own external
  evidence: the SIEM stream of `system_audit_log`, delivered webhooks, or a counterparty Server's
  slice of a federated chain.
- **A store without conditional writes or without versioning.** An S3-compatible store that refuses
  `If-None-Match` is used unconditionally, with a warning, and on it a re-anchored position overwrites
  its key instead of being refused. One that does not answer `ListObjectVersions` cannot report a key
  written twice. Both degradations are reported in the `posture` block on the reconcile and rewind
  endpoints. On such a store the bucket-to-database comparison is the only detection left.
- **A rewind whose lost positions were never anchored.** The comparison is per record: a record whose
  anchored positions all survived the restore reads clean even if entries after them are gone.
- **An object under the prefix that this Server did not write.** COMPLIANCE mode stops an anchor
  being changed or deleted; it does not stop one being created. So a key name is a claim, not
  evidence: before a finding counts, the anchor document under it has to parse and to agree with the
  key it was found at. Keys that fail that are reported as `unverified` and stop nothing. On a bucket
  only this Server writes to, a non-zero `unverified` is worth investigating on its own.
- **Receipts already issued by the SCITT log.** `scitt_entries.leaf_index` is `MAX + 1` per org, so a
  rewind hands those indexes out again over different Signed Statements, and a Receipt issued at the
  old tree size points at a leaf that now holds something else. The refusal above stops the reuse
  while a rewind is unacknowledged, and both `RESTORE_EPOCH` entries carry the per-org SCITT tree size
  at the moment they were written, so a Receipt holder can compare its `tree_size` against the epoch
  and tell which history issued it. Nothing repairs a Receipt already in a holder's hands.
- **Whether a federation peer applied something the restore undid.** A peer holding a terminal state
  refuses a transition that regresses it, and the sender drops that leg as a terminal failure with a
  `FEDERATION_DELIVERY_FAILED` entry on its own chain and a `failed` leg on the record. It does not
  dead-letter, so `/federation/v1/admin/dlq` is the wrong place to look for it.

**Reconcile before the restored Server takes writes.** The next entry on a truncated chain takes a
position the lost history already signed, and webhook receivers, the SIEM, payment platforms and
federation peers already hold that history. A restore also undoes every revocation made after the
backup, and `restore.sh` carries them across: before it drops the database it reads out every API
key, ephemeral certificate, federation peer and trusted issuer revoked after the backup's own
creation instant, plus every unexpired consumed single-use token, and re-applies them once the
restored schema is current. The counts go into the restore marker and onto the `RESTORE_EPOCH`
entry. A credential created after the backup is not in the restored database, so there is nothing
to revoke and the run says how many it skipped. What this cannot cover is a restore onto a host
whose previous database is gone, since there is no record left to read: the closing notes then
name the one-off command that lists what can authenticate against the restored database
(`dist/scripts/post-restore.js --list-active-credentials`), to compare against your own record of
revocations, which the SIEM stream carries as `ADMIN_KEY_REVOKED`, `ACCOUNT_DEACTIVATED` and
`federation.peer_revoked`. The full sequence is in the
[recovery runbook](https://agledger.ai/docs/operations/recovery).

### Kubernetes

`backup.sh`, `restore.sh` and `upgrade.sh` drive `docker compose` and do not work on a cluster. The
chart carries the backup half as a CronJob. Keep its settings in a values file and pass that file on
every upgrade:

```yaml
# your-values.yaml
backup:
  cronJob:
    enabled: true
  persistence:
    enabled: true
  keep: 14
  preUpgrade:
    enabled: true
```

```bash
helm upgrade --install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger \
  --values your-values.yaml
```

`--reuse-values` is the wrong shortcut here and pins `backup.image` to whatever the old chart shipped:
see the upgrade note under [Kubernetes (Helm)](#kubernetes-helm).

It runs `pg_dump -Fc` against `DATABASE_URL_MIGRATE` when the release's Secret holds one (the owner
URL the migration Job uses), and against the workloads' `DATABASE_URL` otherwise. It checks the
archive header before it keeps anything, and writes a `backup-<timestamp>.tar.gz` in the shape `restore.sh` reads,
onto a PersistentVolumeClaim the chart keeps when the release is uninstalled. It records no install
version inside the archive, which the Compose script's archives do, so a restore from one names the
release to return to as yours to decide. `backup.image`
must carry a `pg_dump` no older than the server; it defaults to the bundled PostgreSQL image.
`backup.s3` uploads the same tarball to an S3-compatible bucket instead, and needs an image carrying
both `pg_dump` and the `aws` CLI, which no public image provides.

`backup.preUpgrade.enabled` takes one before the migration Job, at a hook weight ahead of it, and a
failure aborts the upgrade with nothing migrated. It needs a destination that **already exists**, so
the upgrade that first enables it alongside `backup.persistence.enabled` takes no backup: helm
finishes every pre-upgrade hook before it creates an ordinary resource, and the PersistentVolumeClaim
is an ordinary resource. Every upgrade after that one backs up first. To cover the very first one too,
give it a destination the chart did not have to create: `backup.persistence.existingClaim` pointed at
a claim you already have, or `backup.s3`. Splitting it across two upgrades does not work on its own,
because the chart-managed claim renders only when a backup is enabled, so an upgrade that turns on
`backup.persistence` and nothing else creates nothing.

**Restore is a `kubectl` recipe, not a Job.** A restore has questions a template cannot answer: which
archive, whether the connection has the superuser rights the audit event trigger needs, and whether
the runtime role still holds its grants afterwards. `restore.sh` asks them. Copy the archive out and
run it against the database from a host that can reach it, with two flags the cluster case needs:
`--target external`, because a `DATABASE_URL` passed in from the environment that names `localhost`
looks exactly like the bundled container and the script refuses to guess which one to drop; and
`--no-start`, so the run does not bring up a Compose stack beside the cluster's own workloads.
The host has to reach the database from the one-off containers the script runs as well as from
itself (the revocation read, the migration and the privilege check run in the api image), so a
`kubectl port-forward` on a laptop is not enough on its own: a container cannot reach the laptop's
`localhost`. Run it from a bastion or a pod that reaches the database by a routable address, or
forward with `--address 0.0.0.0` and name the host's own address in `DATABASE_URL`. Workloads are
addressed by label rather than by name, because the chart's `fullname` is `<release>-agledger-chart`
and a `fullnameOverride` changes it:

```bash
NS=<namespace>; REL=<release>

# 1. a pod that holds the backup PVC open long enough to read from
kubectl run agl-backups -n "$NS" --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"agl-backups","image":"busybox","command":["sleep","3600"],
    "volumeMounts":[{"name":"b","mountPath":"/backups"}]}],
    "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"'"$REL"'-agledger-chart-backups"}}]}}'
kubectl wait -n "$NS" --for=condition=Ready pod/agl-backups
kubectl exec -n "$NS" agl-backups -- ls -1t /backups

# 2. record the replica counts, then stop the writers. restore.sh does this
#    itself on Compose; here it is yours.
SEL="app.kubernetes.io/instance=$REL,app.kubernetes.io/component in (api,worker)"
kubectl get deploy -n "$NS" -l "$SEL" \
  -o jsonpath='{range .items[*]}{.metadata.name}={.spec.replicas}{"\n"}{end}'
kubectl scale -n "$NS" --replicas=0 deploy -l "$SEL"

# 3. copy one out and restore it with the documented script, naming the
#    release it runs and both database roles the release's Secret holds
kubectl cp "$NS"/agl-backups:/backups/backup-<timestamp>.tar.gz ./backup-<timestamp>.tar.gz
DATABASE_URL='<runtime-role URL, reachable from here and from a container here>' \
DATABASE_URL_MIGRATE='<owner-role URL, the same way>' \
  ./scripts/restore.sh --target external --no-start --version <app version> ./backup-<timestamp>.tar.gz

# 4. run the post-restore steps in the cluster: the commands restore.sh printed
#    last, which create the Job's input Secret from the directory it wrote,
#    start the Job from the chart's post-restore CronJob, and wait for it
PR=$(kubectl get cronjob -n "$NS" -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component=post-restore" \
  -o jsonpath='{.items[0].metadata.name}')
kubectl delete secret -n "$NS" "$PR" --ignore-not-found
kubectl create secret generic -n "$NS" "$PR" --from-file=<the directory restore.sh named>
kubectl create job -n "$NS" --from=cronjob/"$PR" <the Job name restore.sh named>
kubectl wait -n "$NS" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=15m job/<that name>
kubectl logs -n "$NS" job/<that name>
kubectl get job -n "$NS" <that name> -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}{"\n"}'

# 5. bring each Deployment back to the count step 2 recorded (the chart can run
#    either under an HPA, and a count it did not choose is overridden at its
#    next pass), and clean up
kubectl scale -n "$NS" --replicas=<recorded count> deploy/<name>
kubectl delete secret -n "$NS" "$PR"
kubectl delete pod -n "$NS" agl-backups
```

Step 4 is what `restore.sh` does itself after the migration on Compose: it re-applies the
revocations made after the backup (read out of the database before the drop), writes the restore
marker the next boot turns into a `RESTORE_EPOCH` chain entry, and compares the external anchors
against the restored database. Those need the Server's whole configuration, which only the release
holds, so on a cluster they run in a Job with the api's image, env sources, volumes and security
context. The chart renders it as a CronJob that never fires (`postRestore.enabled`, on by default);
without its input Secret the Job exits 2 and names what is missing. The Job succeeds whenever the
steps ran, and its log says what they found; a rewind it finds refuses chain writes until
acknowledged. Leave `postRestore.enabled` on: turning it back on mid-restore is a `helm upgrade`,
which resets the Deployments' replica counts and starts the Server before these steps.
The [recovery runbook](https://agledger.ai/docs/operations/recovery) has the full recipe.

The backup PVC is `ReadWriteOnce`, so on most storage classes that pod has to land on the node the
CronJob last ran on. If it stays `Pending`, `kubectl get pod agl-backups -o wide` and the PVC's
events say which node it wants.

On the bundled-PostgreSQL path there is no PITR and the CronJob is the whole plan, so set its
schedule to your RPO. On an external database the provider's PITR is the shorter path to a
sub-minute RPO and the CronJob is a portable second copy.

## SIEM export

Three channels, all off until `SIEM_ENABLED=true`, and all serving the same bytes for the same row:
a file sink (`SIEM_FILE_ENABLED`, `SIEM_FILE_PATH`), an HTTP push sink (`SIEM_HTTP_ENABLED`,
`SIEM_HTTP_URL`) and a pull endpoint, `GET /v1/siem/stream`. Every knob is documented where it is
set, in `compose/.env.example`.

**The worker drains the push sinks; the API serves the pull endpoint.** Both push channels advance
one shared cursor row, and the sinks are per-process, so two draining processes take alternate
batches. One HTTP collector sees the whole feed either way, because both halves arrive in the same
place. Two file sinks do not: each container's `SIEM_FILE_PATH` holds a slice and nothing in either
file says so. That is why only the worker polls, and why a file sink is the complete feed only under
a single worker replica. Past one replica, use the HTTP sink.

**A collector on loopback or a private address needs no `SSRF_ALLOW_CIDRS`.** `SIEM_HTTP_URL` is
operator configuration, so the egress guard on it refuses only the cloud instance-metadata service,
whether the URL names that address or a hostname resolving to it. A sidecar collector on
`localhost` works as it stands. `SSRF_ALLOW_CIDRS` governs the URLs API callers register (webhooks,
federation peers, trusted-issuer JWKS), and widening it never changes what the SIEM sink may reach,
nor the reverse. A collector behind a
private CA needs `SIEM_HTTP_CA_FILE` (a PEM bundle, which replaces the system roots for this sender)
or `NODE_EXTRA_CA_CERTS` (process-wide, and set before the process starts).

**Splunk.** `SIEM_HTTP_MODE=hec` wraps each event in an HTTP Event Collector envelope and posts to
`/services/collector/event`, which reads the envelope's own `time` and applies no line truncation;
that endpoint answers 400 `No data` to an unwrapped NDJSON body, which is what the default
`SIEM_HTTP_MODE=ndjson` sends. NDJSON mode works against `/services/collector/raw?sourcetype=_json`,
and there Splunk needs a `props.conf` stanza for the sourcetype, or every event carries index time
rather than its own:

```ini
[agledger:ocsf]
INDEXED_EXTRACTIONS = json
TIMESTAMP_FIELDS = time_dt
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%3NZ
TZ = UTC
TRUNCATE = 0
```

`TRUNCATE` is 10000 bytes by default in Splunk and cuts a longer line at the byte, which reaches the
index as unparseable JSON. `SIEM_MAX_EVENT_BYTES` (default 8192, floor 1024) keeps a line under that
by trimming the copied payload largest-key-first; a trimmed line names the keys it dropped under
`agledgerPayloadTruncated`, so a short payload and a trimmed one are distinguishable.

**Other products.** Microsoft Sentinel, IBM QRadar, CrowdStrike and Elastic read this feed through a
collector you run in between: Logstash, Vector, Fluent Bit, or for Sentinel an Azure data collection
rule. Two of them cannot take the push sink directly whatever the format. The Azure Monitor Logs
Ingestion API behind Sentinel requires a JSON array body and a Microsoft Entra bearer from the
client-credentials flow, and Elasticsearch `_bulk` requires an action line before every document.

## Uninstalling

```bash
./scripts/uninstall.sh
```

Stops all containers and removes volumes. `compose/.env` is kept by default; pass `--purge` to remove it too. Volumes belong to the compose project, so on a host running more than one checkout this removes the database both were using.

## Support

```bash
./scripts/support-bundle.sh
```

Collects container logs as written, resource usage, `.env` with every credential value redacted, and database health checks into a single archive. The logs are not filtered, so review the archive before you send it to support@agledger.ai.

## Verifying the Release

**OpenSSF-aligned supply chain.** SLSA Build L3 provenance, Sigstore keyless signing, and SBOM + OpenVEX + malware-scan attestations, all verifiable with no repository access and no AGLedger-hosted endpoint. Releases are **keyless-signed** with [cosign](https://github.com/sigstore/cosign): GitHub Actions OIDC → Sigstore Fulcio → the **public Rekor** transparency log. A valid signature binds to the workflow that built the release, with no static key. **Requires cosign 3.0 or later.**

The commands below read the signature from the registry and the Sigstore trust root over the network. A host that can reach neither verifies the same release from carried material instead: see [Verifying with no network](#verifying-with-no-network).

```bash
IDENTITY='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
ISSUER='https://token.actions.githubusercontent.com'

# Image signature proves the image is a genuine, untampered release
cosign verify --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger/agledger:<version>
```

The complete recipe (Helm chart signature, SBOM/OpenVEX/malware-scan attestations, SLSA Build L3 provenance, and the signed conformance corpus) is in [SECURITY.md](SECURITY.md). The CycloneDX SBOM and OpenVEX documents are also attached to each release for direct download.

**Verify the installer itself.** `install.sh` and `helm-install.sh` are advertised as `curl ... | bash`,
which makes them the one artifact you run before anything of ours has been verified. Each release
publishes a SHA-256 and a Sigstore bundle for both:

```bash
R=https://github.com/agledger-ai/install/releases/latest/download
curl -fsSLO $R/helm-install.sh -O $R/helm-install.sh.sha256
sha256sum -c helm-install.sh.sha256 && bash helm-install.sh
```

Both files come from the release, not the script from `agledger.ai` and the checksum from the
release. `agledger.ai/helm-install.sh` serves this repository's `main`, which moves between releases,
so a checksum taken at the tag would not describe it and a mismatch would tell you nothing.

Or check authorship rather than just integrity, against the same keyless identity as the image:

```bash
curl -fsSLO https://github.com/agledger-ai/install/releases/latest/download/helm-install.sh.sigstore.json
cosign verify-blob --bundle helm-install.sh.sigstore.json \
  --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" helm-install.sh
```

**Make verification mandatory.** `install.sh`, `upgrade.sh` and `helm-install.sh` verify signatures when cosign is present, and proceed with a warning when it is not, which is the right default for an evaluation and the wrong one for production. Set `AGLEDGER_REQUIRE_VERIFY=true` and a run that cannot verify refuses to install instead:

```bash
AGLEDGER_REQUIRE_VERIFY=true ./scripts/install.sh --version <version>
```

Set it in CI and on production hosts. The lever in the other direction, `--skip-verify`, exists for local development and should never reach either.

### Verifying with no network

Every release attaches `agledger-<version>-offline-verification.tar.gz`: the signature and attestation bundles, the signed index and platform manifests, and the Sigstore `trusted_root.json` they verify against. It ships with a `.sha256` and a `.sigstore.json` of its own. Check that signature on a host that still has a network, because the archive carries the trust anchor every later check reads:

```bash
cosign verify-blob --bundle agledger-<version>-offline-verification.tar.gz.sigstore.json \
  --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger-<version>-offline-verification.tar.gz
```

Then unpack it on the host that holds the image and run one command:

```bash
tar xzf agledger-<version>-offline-verification.tar.gz
./scripts/verify-release.sh --version <version> --bundle-dir ./offline-verification
```

It checks the signature and all three attestations, asserts the malware scan reports `no-detections`, and then ties the image in this host's store to the signed index by config digest, which is the one identifier a `docker save` / `load` / push round trip preserves. Add `--image <your mirror>` when the image was mirrored.

`install.sh` and `upgrade.sh` run the same check when `AGLEDGER_VERIFY_BUNDLE_DIR` names that directory, so an air-gapped install satisfies `AGLEDGER_REQUIRE_VERIFY=true` rather than having to be run without it. The full air-gap procedure, including how to mirror so the mirror keeps the signature, is in [air-gap/README.md](air-gap/README.md).

## Licensing

**Running AGLedger in production requires a license. The Developer Edition license is free, so get one.** Register at [agledger.ai](https://agledger.ai) and you have it in a minute: no credit card, no account, and the key validates offline with no phone-home.

Unlicensed use is permitted for evaluation, development, and testing only, and only for the Evaluation Period the license sets. The Developer Edition key is what grants production rights and the written terms that come with them, and it is what keeps an install licensed once that period ends.

Every feature ships in every image. The one line the Developer Edition grant does not cross is the database: it is licensed for the PostgreSQL bundled with the Compose and Helm deployments, and pointing the Server at an external or managed PostgreSQL (Aurora, RDS, Cloud SQL, or a self-managed server) requires an Enterprise license. Enterprise is also where the warranty, indemnification, and liability coverage in the Software License Agreement live, along with Support under the Support Terms. See [agledger.ai/pricing](https://agledger.ai/pricing).

An install outside its grant is outside the license whether or not anything stops it. Neither boundary is enforced in software: every feature stays enabled and the Server logs a periodic notice instead of degrading or blocking.

The [LICENSE](LICENSE) in this repository is the **Installer License**. It governs your use of the deployment scripts, Compose files, Helm chart, and related packaging in this repository. The AGLedger server software itself (the `agledger/agledger` Docker image) is governed by the separate **Software License Agreement** at [agledger.ai/license](https://agledger.ai/license). Both apply when you run a full AGLedger deployment; where they conflict, the SWLA controls.

## Links

- [agledger.ai](https://agledger.ai): product site
- [agledger.ai/docs](https://agledger.ai/docs): documentation
- [SECURITY.md](SECURITY.md): release verification, SBOM, provenance
- [Docker Hub](https://hub.docker.com/r/agledger/agledger): server image
