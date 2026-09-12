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

A fresh install with no `--version` takes the latest release from Docker Hub and records it in `compose/.env`. Every later run of `install.sh` stays on that version, so re-running it is safe: it reconciles configuration and never moves the install between releases. That holds once the recorded version is a release number; if `compose/.env` still names something else, a non-release tag from a testbed build or air-gap mirror, or the `.env.example` placeholder `latest` never overwritten, a plain re-run cannot tell a deliberate pin from a placeholder and refuses instead of guessing, naming both `--version` (stay on it) and `upgrade.sh` (move) as the ways forward. A re-run that changes anything in `compose/.env` recreates the containers whose configuration changed, so the repair is live when the run ends rather than pending a restart you were not told about; a re-run that changes nothing leaves every container alone. That covers the secrets a newer release expects and an older install has none of, such as the `/metrics` scrape token, and it covers the monitoring stack: if the collector, Jaeger, Prometheus and Grafana are running, a plain re-run brings them with it whether or not you pass `--with-monitoring`. Two of those are the exception to "changes nothing, touches nothing": the collector and Prometheus read their whole configuration once, at start, from a file mounted out of this checkout, and Compose hashes the service definition rather than that file's contents, so every run restarts those two and says so. It is how a configuration change reaches them at all, and neither holds anything: Prometheus keeps its series on a volume and the collector holds at most one five-second batch. If the registry is unreachable and `compose/.env` already pins a digest this host holds locally, the run says so and reconciles on those bytes instead of refusing; nothing is verified on such a run. Changing releases is `upgrade.sh`, which backs up first and writes the marker that says what to roll back to:

```bash
./scripts/upgrade.sh 1.4.0
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

Reference values: `helm/agledger/values.yaml`. Or run `./scripts/helm-install.sh` for a guided install that generates secrets and produces a values file.

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
renders `trusted-issuers.yaml` at the provisioning root, and `provisioning.existingConfigMaps.trustedIssuers`
mounts a ConfigMap you manage (its key has to be named `trusted-issuers.yaml`).

**Monitoring.** With the Prometheus Operator installed, the chart ships its own alerts and dashboards
rather than leaving you to copy YAML:

```bash
helm upgrade agledger ... \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.prometheusRule.enabled=true \
  --set monitoring.grafanaDashboards.enabled=true
```

These render the same rule and dashboard files the Compose stack mounts, so the two packaging paths
cannot drift. `GET /metrics` is gated under `NODE_ENV=production`, which the chart sets: it mints a
bearer token into the release Secret, preserved across upgrades, and the ServiceMonitor presents it.
Read it with `kubectl get secret <release>-agledger-chart -o jsonpath='{.data.METRICS_AUTH_TOKEN}' | base64 -d`
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

- Direct connections only. RDS Proxy and PgBouncer (transaction mode) are incompatible, because pg-boss requires `LISTEN`/`NOTIFY`.
- The migration user needs schema-creation privileges. See `compose/.env.example`.
- The runtime user (`DATABASE_URL`) needs DML plus `CREATE` on the database. Migrations grant DML to the role named `agledger_app` specifically, so a non-owner role called anything else receives nothing; make yours a member instead, with `GRANT agledger_app TO "your_role" WITH INHERIT TRUE`. The `CREATE` grant is what pg-boss uses to install its own schema on first start, and can be revoked once the Server has booted successfully.
- Set `DATABASE_POOL_MAX` to match your database's connection limits.

Both installers check that runtime role after migrating and before anything starts serving, so a role that cannot serve stops the install with the missing grant named instead of leaving crash-looping workloads behind a success message. On Compose the check is a step in `install.sh`. On the chart it is a `pre-install`/`pre-upgrade` hook Job, so `helm install` exits non-zero and creates no workload; migrations have run by then, and so have the release's ConfigMap and Secret, which are hook resources and outlive a `helm uninstall`, but the API and Worker are still unmade. Read the hook's report with:

```bash
kubectl logs -n <namespace> --tail=-1 \
  -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=preflight
```

`scripts/helm-install.sh` prints it for you. Apply what it asks for and run the installer again: a failed release keeps its name, and the re-run reconciles it in place rather than refusing the name, so nothing needs uninstalling first. It reads the version off the release's own revisions, including a first install that never reached `deployed`, so a plain re-run stays on the version that install named.

`restore.sh` asks it too, after the restore and before it starts anything. A restore rebuilds the database the runtime role's access rests on, so it is the same question at a different moment: your rows are back, and the check answers whether the role can read them. Stopping there leaves the data restored and the API and Worker still stopped, rather than a stack coming up unhealthy with nothing naming the reason. Stopping there still prints everything the run has to tell you about the database now on disk, including that `api_keys` came from the backup and which keys that invalidates, so the grant you run and the credential you use are both in front of you.

`restore.sh` also asks the migration question, and asks it first, before it stops anything or drops the database. The schema carries the `agledger_block_audit_drop` event trigger, `CREATE EVENT TRIGGER` is superuser-only, and `pg_restore` does not stop when it is refused: it reports the refusal among its own "errors ignored on restore", puts every row back and exits 1. That is the one failure that costs you something, because the database it would go back to was dropped at the top of the run. Asked first, the refusal is free, and it prints the same provider grants `install.sh` does. This matters more on a restore than on an install: DR routinely runs against a rebuilt server whose roles were recreated by whatever provisioning ran, which is exactly how the grant goes missing.

The gate asks whether the role holds a superuser-equivalent role, which is not quite the same question as whether the server will accept the statement. So `restore.sh` also checks, after the restore, that the trigger is actually there, and if it is not it names what is missing and prints the single `CREATE EVENT TRIGGER` statement that repairs it. Your rows and the signature chain are unaffected either way: what the trigger provides is layer 2 of the tamper model, the DDL guard that refuses an in-band `DROP` of `audit_vault`, its partitions, the `org_admin_read*` tables and `vault_signing_keys`. The row-level DML triggers, the signed checkpoints and the external anchors are all independent of it.

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
- **Consumers need a current verifier.** Anyone verifying your chain offline needs `@agledger/verify` 1.4.0 or later. The algorithm support lives in its `@agledger/verify-core` dependency rather than in `verify` itself; 1.4.0 is the `verify` release that resolves a core carrying ES256 under every install shape, including a consumer with an older core pinned at the top level. Quote the `verify` version, because that is the package people install. Your Server publishes the floor per key as `minVerifierVersion` at `GET /v1/verification-keys`. **Tell them before they run one**, because a verifier that cannot compute the algorithm does not reliably say so: builds from `verify-core` 1.1.0 on report `CHAIN_UNSUPPORTED_ALGORITHM` and name the fix, but older builds have no such code path and report a signature failure instead, which reads as tampering on an intact chain.

**Licensing note.** Ed25519 is itself FIPS-approved (FIPS 186-5), and validated modules that implement it exist. The exclusion here is the vintage of the FIPS provider shipped with the runtime base image, not a property of the algorithm.

**Switching an install that already has a chain.** Do not reinstall: entries already written must keep verifying. Rotate instead.

```bash
# 1. generate a P-256 key
docker run --rm agledger/agledger:<version> dist/scripts/generate-signing-key.js --algorithm es256

# 2. put the new VAULT_SIGNING_KEY and AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true in compose/.env

# 3. restart. THIS is what rotates: on boot the Server reconciles the key
#    registry to the configured VAULT_SIGNING_KEY, retiring the previous
#    active key and activating the new one.
docker compose up -d --force-recreate

# 4. confirm the registry agrees
curl -s http://localhost:3001/v1/verification-keys \
  | jq '.data[] | {keyId, algorithm, status, activatedAt, retiredAt}'
```

You should see the new key `active` and the old one `retired`, with the retirement instant matching the restart.

`POST /v1/admin/vault/signing-keys/rotate` exists for the case where the registry has not caught up with the configured key (it is the same reconciliation, on demand). After a restart it has already run, so the endpoint returns `status: "already_active"`. That is the expected answer there, not a failure.

Rotation retires the old key, it does not delete it. `GET /v1/verification-keys` keeps serving every historical public key with the exact instants it was active (`activatedAt` / `retiredAt`), which is what lets a verifier check each entry against the key that actually signed it. Entries written before the rotation keep verifying under the retired Ed25519 key; entries after it use ES256. No re-signing, and the chain stays continuous.

Rotating because a key leaked is a different job from rotating on schedule. Containment is the same restart; what follows it is scoping the window the key was exposed in and deciding what you can still stand behind. There is no `compromised` key status and no revocation: a retired key keeps verifying the entries it signed, which is correct for a routine rotation and means the Server will not flag records signed while the key was out. External anchors are what bound that span. [Signing-key compromise](https://agledger.ai/docs/operations/key-compromise) is the runbook.

Re-running `install.sh` with `AGLEDGER_SIGNING_ALGORITHM` set does **not** change the algorithm of an existing install. The signing key is generated only alongside the other secrets, so a run that finds an existing `.env` keeps the key it already has; the installer says so rather than reporting a success that did not happen.

**Verifying FIPS is actually on.** Ask the running container:

```bash
docker compose exec agledger-api /nodejs/bin/node -e "console.log(require('crypto').getFips())"   # 1 when active
```

With the provider active and an ES256 key, the install runs normally: records notarize, gates evaluate, and a chain scan (`POST /v1/admin/vault/scan`, then poll the returned job at `GET /v1/admin/vault/scan/{jobId}`) reports the chain healthy. Every release blocks on a boot gate that runs this exact configuration on both architectures, asserting both that the ES256 serve path works and that a federation-configured Server refuses to start under it.

### Federation (link multiple Servers)

AGLedger has a single role: Server. To federate, run more than one Server (each a full, independent install with its own database and signing key) and link them so chains can reference records across Servers. There is no hub, gateway, or central coordinator: peers exchange public keys out of band and handshake directly via `POST /federation/v1/peer`. Configure it by setting the `AGLEDGER_FEDERATION_*` keys in `compose/.env`; generate them with `./scripts/generate-federation-keys.sh` (see `compose/.env.example`). On Kubernetes there is no checkout to run that from, so generate the key in the pod: `kubectl exec deploy/<release>-agledger-chart-api -- /nodejs/bin/node dist/scripts/generate-federation-keys.js --stdout`. Use `--stdout` in any container: the image runs with a read-only root filesystem, and that mode writes nothing to disk. The chart-managed Secret carries only the engine's own keys and a `helm upgrade` re-renders it, so keep the federation key in a Secret you manage and reference it from `extraEnv` with a `secretKeyRef` (see the `extraEnv` block in values.yaml). Full setup is at [agledger.ai/docs](https://agledger.ai/docs).

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

Commands: `bootstrap install upgrade status health key logs tunnel shell uninstall [--purge]`. Flags can be set as `AGL_*` environment variables to pin a host once. It deploys the Developer Edition (Compose on Docker CE, bundled PostgreSQL), which is free and production-ready; for production, set `AGLEDGER_EXTERNAL_URL` and front the API with TLS. For multi-node scale, HA, or an external database, see the [Helm chart](#kubernetes-helm). The chart runs under Developer Edition on its bundled PostgreSQL; only pointing it at an external database requires Enterprise. Run `./scripts/agl-deploy.sh --help` for the full reference.

## Upgrading

Refresh the install scripts first, then upgrade:

```bash
git pull
./scripts/upgrade.sh <version>
```

`upgrade.sh` never updates itself, only the image, and a release's `.env` reconcile steps ship in the new script: minting the `METRICS_AUTH_TOKEN` that the production default for `/metrics` now requires is one of them. Running an older copy skips them. If you already upgraded with one, `git pull` and re-run `upgrade.sh` against the version you are on: it reconciles `.env`, prints the `docker compose up -d` that makes the repairs live, and stops without pulling, backing up or restarting anything. `restore.sh` performs the same reconcile before it starts the stack, so a DR restore onto a host whose `compose/.env` predates those repairs does not bring up a Server missing them.

"Already on that version" means the stack is serving it. If `.env` names the target and the API is not answering `/health`, the run treats it as an interrupted upgrade rather than a no-op: it re-attempts the restart and leaves the rollback marker holding the version the first attempt recorded.

"Serving" throughout means the API answers `/health/ready`, the endpoint that runs a query, not the static 200 at `/health`. A Server pointed at a database that is down, gone or refusing its credentials answers the second one.

The upgrade script creates a backup before upgrading, and writes `backup/.pre-upgrade-version-<compose project>` naming what to roll back to. That marker is written even under `--skip-backup`, and even on a host with no `backup/` directory yet. Rollback is `./scripts/restore.sh <backup>`: each archive records the version it was taken from, and the restore returns the install to that version, because the dump and the schema have to agree. It fetches that image before it drops anything and refuses with the database untouched if it cannot, naming both ways forward. Where it does not move the version at all (an archive too old to carry the record, or `--keep-version`), the run says in one line which version is actually serving, and where it knows which version to return to, the command that gets there.

On an external database, `restore.sh` restores into the database `DATABASE_URL` names, and drops and recreates that one. `POSTGRES_DB` configures the bundled PostgreSQL container and has no bearing on an external install. Before dropping, it checks the database looks like an AGLedger one (a `public.records` table); on a shared managed instance, where a database of the same name may belong to something else, that check is what stands between a restore and an unrecoverable drop. Pass `--force` to restore into a database that does not have the table yet.

The dump's privileges are restored with it: the DML grants, the `ALTER DEFAULT PRIVILEGES`, and the append-only `REVOKE`s on the audit chain, so a least-privilege role comes back able to serve. Restoring onto a server that does not carry the same roles (a cross-server DR) reports the grants it could not apply and continues; the runtime-role check that follows decides whether the Server starts.

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
that carries no such record (one from an earlier release, or one the chart's backup Job wrote) leaves
the install where it is, and the run says so. It fetches that image before it
drops anything, and refuses with the database untouched if it cannot. Two flags change what it does:
`--force` restores into a database that does not carry the `public.records` table yet, and
`--keep-version` restores the data onto the release the install is on now, which re-applies that
release's migrations over the older dump.

`--keep` is a count of archives to retain and has a floor of 1: the run keeps the backup it just
took, so 0 is not a retention policy and is refused rather than honoured. To remove backups, delete
them from the backup directory.

Each run writes one timestamped tarball holding a `pg_dump` custom-format dump of the whole database
(`db.dump`) and a CSV export of the signing-key registry's **public** keys. Private signing keys are
never in the database and never in a backup. Before the script reports success it checks that
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
checks hash, link and position integrity against the restored database and will report that chain
healthy.

Only evidence held **outside** the database can tell you where the chain used to end. `vault_checkpoints`
cannot: it is an ordinary table in the same database, so a recovery to time T rolls the checkpoints
back with the chain, and the restored checkpoint agrees with the restored truncated chain. External
anchors are the exception, and the only one. With `VAULT_ANCHOR_ENABLED=true` each checkpoint is also
written to S3-compatible storage under COMPLIANCE-mode object lock, where the database recovery cannot
reach it, and `POST /v1/admin/vault/anchors/verify` compares the two. If you do not anchor, nothing in
the product can distinguish a correct PITR restore from one that silently landed short: reconcile
against your own external evidence instead, such as the SIEM stream of `system_audit_log`, delivered
webhooks, or a counterparty Server's slice of a federated chain. The full sequence is in the
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

It runs `pg_dump -Fc` against the same `DATABASE_URL` the workloads use, checks the archive header
before it keeps anything, and writes a `backup-<timestamp>.tar.gz` in the shape `restore.sh` reads,
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
run it against the database from a host that can reach it. Workloads are addressed by label rather
than by name, because the chart's `fullname` is `<release>-agledger-chart` and a `fullnameOverride`
changes it:

```bash
NS=<namespace>; REL=<release>

# 1. a pod that holds the backup PVC open long enough to read from
kubectl run agl-backups -n "$NS" --restart=Never --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"agl-backups","image":"busybox","command":["sleep","3600"],
    "volumeMounts":[{"name":"b","mountPath":"/backups"}]}],
    "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"'"$REL"'-agledger-chart-backups"}}]}}'
kubectl wait -n "$NS" --for=condition=Ready pod/agl-backups
kubectl exec -n "$NS" agl-backups -- ls -1t /backups

# 2. stop the writers. restore.sh does this itself on Compose; here it is yours.
kubectl scale -n "$NS" --replicas=0 \
  deploy -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component in (api,worker)"

# 3. copy one out and restore it with the documented script
kubectl cp "$NS"/agl-backups:/backups/backup-<timestamp>.tar.gz ./backup-<timestamp>.tar.gz
DATABASE_URL='<the same URL, reachable from here>' ./scripts/restore.sh ./backup-<timestamp>.tar.gz

# 4. bring them back, and clean up
kubectl scale -n "$NS" --replicas=1 \
  deploy -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component in (api,worker)"
kubectl delete pod -n "$NS" agl-backups
```

The backup PVC is `ReadWriteOnce`, so on most storage classes that pod has to land on the node the
CronJob last ran on. If it stays `Pending`, `kubectl get pod agl-backups -o wide` and the PVC's
events say which node it wants.

On the bundled-PostgreSQL path there is no PITR and the CronJob is the whole plan, so set its
schedule to your RPO. On an external database the provider's PITR is the shorter path to a
sub-minute RPO and the CronJob is a portable second copy.

## Uninstalling

```bash
./scripts/uninstall.sh
```

Stops all containers and removes volumes. `compose/.env` is kept by default; pass `--purge` to remove it too. Volumes belong to the compose project, so on a host running more than one checkout this removes the database both were using.

## Support

```bash
./scripts/support-bundle.sh
```

Collects container logs, resource usage, redacted configuration, and database health checks into a single archive. No application data or secrets are included. Send the archive to support@agledger.ai.

## Verifying the Release

**OpenSSF-aligned supply chain.** SLSA Build L3 provenance, Sigstore keyless signing, and SBOM + OpenVEX + malware-scan attestations, all verifiable offline with no repository access. Releases are **keyless-signed** with [cosign](https://github.com/sigstore/cosign): GitHub Actions OIDC → Sigstore Fulcio → the **public Rekor** transparency log. A valid signature binds to the workflow that built the release, with no static key. **Requires cosign 3.0 or later.**

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

## Licensing

**Running AGLedger in production requires a license. The Developer Edition license is free, so get one.** Register at [agledger.ai](https://agledger.ai) and you have it in a minute: no credit card, no account, and the key validates offline with no phone-home.

Registering is not a formality. Unlicensed use is permitted for evaluation, development, and testing only. The Developer Edition key is what grants you production rights and the written terms that come with them, and it is what gives us a record of who is running the software. Both sides are better off for it, which is why it costs nothing.

Every feature ships in every image. The one line the Developer Edition grant does not cross is the database: it is licensed for the PostgreSQL bundled with the Compose and Helm deployments, and pointing the Server at an external or managed PostgreSQL (Aurora, RDS, Cloud SQL, or a self-managed server) requires an Enterprise license. Enterprise is also where the warranty, indemnification, and liability coverage in the Software License Agreement live, along with Support under the Support Terms. See [agledger.ai/pricing](https://agledger.ai/pricing).

We do not enforce either boundary in software. Every feature stays enabled and the Server logs a periodic notice instead of degrading or blocking. That is a deliberate choice about how we treat operators, not a statement that the license is optional: running unregistered in production, or running Developer Edition against an external database, is outside the grant whether or not anything stops you.

The [LICENSE](LICENSE) in this repository is the **Installer License**. It governs your use of the deployment scripts, Compose files, Helm chart, and related packaging in this repository. The AGLedger server software itself (the `agledger/agledger` Docker image) is governed by the separate **Software License Agreement** at [agledger.ai/license](https://agledger.ai/license). Both apply when you run a full AGLedger deployment; where they conflict, the SWLA controls.

## Links

- [agledger.ai](https://agledger.ai): product site
- [agledger.ai/docs](https://agledger.ai/docs): documentation
- [SECURITY.md](SECURITY.md): release verification, SBOM, provenance
- [Docker Hub](https://hub.docker.com/r/agledger/agledger): server image
