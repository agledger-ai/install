# AGLedger Install

Install scripts, Docker Compose files, and Helm chart for [AGLedger](https://agledger.ai).

AGLedger is a cryptographic notary for automated operations. An agent notarizes what it is about to do, then notarizes what was done. Both are signed and hash-chained. For workloads where the deliverable is measurable (procurement, finance, compliance), an optional gated mode adds a receipt + verdict phase. AGLedger does not inspect or judge deliverable content; it records what was claimed and when, signed and chainable.

This repository contains only the deployment packaging. The server image is distributed on [Docker Hub](https://hub.docker.com/r/agledger/agledger) and the Helm chart on OCI at `oci://registry-1.docker.io/agledger/agledger-chart`.

## Prerequisites

- Docker Engine 24.0 or later
- Docker Compose v2
- 4 GB RAM minimum (8 GB recommended)
- 2 CPU cores minimum (4 recommended)
- 20 GB free disk

## Quick Start

```bash
git clone https://github.com/agledger-ai/install.git
cd install
./scripts/install.sh
```

The API is reachable at `http://localhost:3001` once startup completes. Swagger UI is at `http://localhost:3001/docs`.

`install.sh` generates cryptographic secrets locally, writes `compose/.env`, starts PostgreSQL, runs migrations, creates a platform API key (printed once, so save it), and starts the API and worker.

A fresh install with no `--version` takes the latest release from Docker Hub and records it in `compose/.env`. Every later run of `install.sh` stays on that version, so re-running it is safe: it reconciles configuration and never moves the install between releases. Changing releases is `upgrade.sh`, which backs up first and writes the marker that says what to roll back to:

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
COMPOSE_PROJECT_NAME=agledger-2 AGLEDGER_HOST_PORT=3011 POSTGRES_HOST_PORT=5442 ./scripts/install.sh
```

The refusal is scoped to a directory whose stack still exists. After `uninstall.sh` (which keeps `compose/.env` so a reinstall preserves the signing key) there is nothing left to orphan, so the same checkout can be reinstalled under any project name.

### Kubernetes (Helm)

Production clusters:

```bash
helm install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger --create-namespace \
  --values your-values.yaml
```

Reference values: `helm/agledger/values.yaml`. Or run `./scripts/helm-install.sh` for a guided install that generates secrets and produces a values file.

#### OpenShift

Add `--set openshift.enabled=true`:

```bash
helm install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger --create-namespace \
  --set openshift.enabled=true \
  --values your-values.yaml
```

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

`scripts/helm-install.sh` prints it for you. Apply what it asks for and re-run; a failed release keeps its name, so clear it with `helm uninstall <release>` first if it still appears in `helm list`.

`restore.sh` asks it too, after the restore and before it starts anything. A restore rebuilds the database the runtime role's access rests on, so it is the same question at a different moment: your rows are back, and the check answers whether the role can read them. Stopping there leaves the data restored and the API and Worker still stopped, rather than a stack coming up unhealthy with nothing naming the reason.

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

- **Federation is not available.** The federation transport is Ed25519 and X25519 by design. A Server configured with both ES256 and federation keys refuses to boot, naming the conflict, rather than starting with a transport it cannot sign for.
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

Re-running `install.sh` with `AGLEDGER_SIGNING_ALGORITHM` set does **not** change the algorithm of an existing install. The signing key is generated only alongside the other secrets, so a run that finds an existing `.env` keeps the key it already has; the installer says so rather than reporting a success that did not happen.

**Verifying FIPS is actually on.** Ask the running container:

```bash
docker compose exec agledger-api /nodejs/bin/node -e "console.log(require('crypto').getFips())"   # 1 when active
```

With the provider active and an ES256 key, the install runs normally: records notarize, gates evaluate, and a chain scan (`POST /v1/admin/vault/scan`, then poll the returned job at `GET /v1/admin/vault/scan/{jobId}`) reports the chain healthy. Every release blocks on a boot gate that runs this exact configuration on both architectures, asserting both that the ES256 serve path works and that a federation-configured Server refuses to start under it.

### Federation (link multiple Servers)

AGLedger has a single role: Server. To federate, run more than one Server (each a full, independent install with its own database and signing key) and link them so chains can reference records across Servers. There is no hub, gateway, or central coordinator: peers exchange public keys out of band and handshake directly via `POST /federation/v1/peer`. Configure it by setting the `AGLEDGER_FEDERATION_*` keys in `compose/.env`; generate them with `./scripts/generate-federation-keys.sh` (see `compose/.env.example`). Full setup is at [agledger.ai/docs](https://agledger.ai/docs).

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

```bash
./scripts/upgrade.sh <version>
```

The upgrade script creates a backup before upgrading. Rollback with `./scripts/restore.sh <backup>`.

On an external database, `restore.sh` restores into the database `DATABASE_URL` names, and drops and recreates that one — `POSTGRES_DB` configures the bundled PostgreSQL container and has no bearing on an external install. Before dropping, it checks the database looks like an AGLedger one (a `public.records` table); on a shared managed instance, where a database of the same name may belong to something else, that check is what stands between a restore and an unrecoverable drop. Pass `--force` to restore into a database that does not have the table yet.

The dump's privileges are restored with it — the DML grants, the `ALTER DEFAULT PRIVILEGES`, and the append-only `REVOKE`s on the audit chain — so a least-privilege role comes back able to serve. Restoring onto a server that does not carry the same roles (a cross-server DR) reports the grants it could not apply and continues; the runtime-role check that follows decides whether the Server starts.

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
