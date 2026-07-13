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

## Deployment Paths

### Docker Compose (default)

Single-node deployments, evaluation, and small-to-medium workloads.

```bash
./scripts/install.sh
```

All configuration lives in `compose/.env`. See `compose/.env.example` for the full list of variables.

### Kubernetes (Helm)

Production clusters:

```bash
helm install agledger oci://registry-1.docker.io/agledger/agledger-chart \
  --namespace agledger --create-namespace \
  --values your-values.yaml
```

Reference values: `helm/agledger/values.yaml`. Or run `./scripts/helm-install.sh` for a guided install that generates secrets and produces a values file.

### External Database

The bundled PostgreSQL container is the default. To point at Aurora, RDS, Cloud SQL, or another managed Postgres, set `DATABASE_URL` in `compose/.env` and use `--external-db`:

```bash
./scripts/install.sh --external-db
```

Requirements:

- Direct connections only. RDS Proxy and PgBouncer (transaction mode) are incompatible, because pg-boss requires `LISTEN`/`NOTIFY`.
- The migration user needs schema-creation privileges. See `compose/.env.example`.
- Set `DATABASE_POOL_MAX` to match your database's connection limits.

### Air-Gapped / Restricted-Network Installs

`install.sh --image` lets you point at an internal registry. See [air-gap/README.md](air-gap/README.md) for the full flow.

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

Commands: `bootstrap install upgrade status health key logs tunnel shell uninstall [--purge]`. Flags can be set as `AGL_*` environment variables to pin a host once. It deploys the Developer Edition (Compose on Docker CE, bundled PostgreSQL), which is free and production-ready; for production, set `AGLEDGER_EXTERNAL_URL` and front the API with TLS. For multi-node scale, HA, or an external database, see the [Helm chart](#kubernetes-helm) (Enterprise). Run `./scripts/agl-deploy.sh --help` for the full reference.

## Upgrading

```bash
./scripts/upgrade.sh <version>
```

The upgrade script creates a backup before upgrading. Rollback with `./scripts/restore.sh <backup>`.

## Uninstalling

```bash
./scripts/uninstall.sh
```

Stops all containers and removes volumes. `compose/.env` is kept by default; pass `--purge` to remove it too.

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

## Licensing

AGLedger Developer Edition is free to self-host for evaluation, development, and production use. Register at [agledger.ai](https://agledger.ai) to obtain a Developer Edition License Key. Enterprise Edition is available for customers who need the warranty, indemnification, and liability coverage in the Software License Agreement, or who elect to purchase Support under the Support Terms. See [agledger.ai/pricing](https://agledger.ai/pricing).

The [LICENSE](LICENSE) in this repository is the **Installer License**. It governs your use of the deployment scripts, Compose files, Helm chart, and related packaging in this repository. The AGLedger server software itself (the `agledger/agledger` Docker image) is governed by the separate **Software License Agreement** at [agledger.ai/license](https://agledger.ai/license). Both apply when you run a full AGLedger deployment; where they conflict, the SWLA controls.

## Links

- [agledger.ai](https://agledger.ai): product site
- [agledger.ai/docs](https://agledger.ai/docs): documentation
- [SECURITY.md](SECURITY.md): release verification, SBOM, provenance
- [Docker Hub](https://hub.docker.com/r/agledger/agledger): server image
