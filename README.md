# AGLedger Install

Install scripts, Docker Compose files, and Helm chart for [AGLedger](https://agledger.ai).

AGLedger is an accountability layer for automated operations. It records what an agent or process was asked to do (mandate), what it delivered (receipt), and whether the principal accepted the result (verdict) — with a hash-chained, Ed25519-signed audit trail. AGLedger does not inspect or judge deliverable content; it records acceptance, not correctness.

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

`install.sh` generates cryptographic secrets locally, writes `compose/.env`, starts PostgreSQL, runs migrations, creates a platform API key (printed once — save it), and starts the API and worker.

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

- Direct connections only. RDS Proxy and PgBouncer (transaction mode) are incompatible — pg-boss requires `LISTEN`/`NOTIFY`.
- The migration user needs schema-creation privileges. See `compose/.env.example`.
- Set `DATABASE_POOL_MAX` to match your database's connection limits.

### Air-Gapped / Restricted-Network Installs

`install.sh --image` lets you point at an internal registry. See [air-gap/README.md](air-gap/README.md) for the full flow.

### Federation (Gateway / Hub)

Enterprise deployments can run in Gateway or Hub mode. See `compose/docker-compose.federation.yml`.

## Upgrading

```bash
./scripts/upgrade.sh <version>
```

The upgrade script creates a backup before upgrading. Rollback with `./scripts/restore.sh <backup>`.

## Uninstalling

```bash
./scripts/uninstall.sh
```

Stops all containers and removes volumes. `compose/.env` is kept by default — pass `--purge` to remove it too.

## Support

```bash
./scripts/support-bundle.sh
```

Collects container logs, resource usage, redacted configuration, and database health checks into a single archive. No application data or secrets are included. Send the archive to support@agledger.ai.

## Telemetry

Developer Edition installs send an anonymous heartbeat (version, uptime, deployment mode — no usage data, no identifiers) every 48 hours. Disable it by setting `AGLEDGER_TELEMETRY=false` in `compose/.env`. Enterprise licenses disable telemetry automatically.

## Verifying the Release

The Docker image and Helm chart are signed with [cosign](https://github.com/sigstore/cosign). The public key is at `cosign.pub` in this repo.

```bash
# Image signature — proves the image wasn't swapped between push and pull
cosign verify --key cosign.pub agledger/agledger:<version>

# Helm chart signature
cosign verify --key cosign.pub oci://registry-1.docker.io/agledger/agledger-chart:<version>

# SLSA L2 build provenance — cryptographic proof of the source commit and CodeBuild
# run that produced the image. The output includes the git commit, build ID, and
# start/finish timestamps.
cosign verify-attestation --key cosign.pub --type slsaprovenance1 agledger/agledger:<version>
```

SBOM and SLSA provenance attestations are attached to each release on this repo.

## Licensing

AGLedger Developer Edition is free to self-host and evaluate. Enterprise licensing (federation, extended support, indemnity) is available — contact sales@agledger.ai.

This installer is proprietary software. See [LICENSE](LICENSE).

## Links

- [agledger.ai](https://agledger.ai) — product site
- [agledger.ai/docs](https://agledger.ai/docs) — documentation
- [agledger.ai/trust](https://agledger.ai/trust) — security, SBOM, provenance
- [Docker Hub](https://hub.docker.com/r/agledger/agledger) — server image
