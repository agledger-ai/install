# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in AGLedger, report it privately. Do not open a public GitHub issue.

Email **security@agledger.ai** with:

- A description of the vulnerability
- Steps to reproduce
- Impact assessment — what an attacker could achieve
- Affected components (services, endpoints, configurations)
- Environment details: version, deployment method (Compose or Helm), OS, relevant configuration
- Proof of concept: screenshots, logs, or code snippets, if available

For sensitive reports, request our PGP key by emailing **security@agledger.ai** and we will arrange an encrypted channel.

## Severity and Response

| Severity | Definition | Acknowledgment | Patch target |
|---|---|---|---|
| Critical | Immediate risk of data breach, auth bypass, or RCE | 24 hours | 72 hours |
| High | Significant risk requiring prompt attention | 48 hours | 1 week |
| Medium | Moderate risk or requiring specific conditions | 1 week | 30 days |
| Low | Minor risk with minimal impact | 2 weeks | Next release |

You will be kept informed of progress and credited in the advisory unless you ask to remain anonymous.

## Safe Harbor

AGLedger supports good-faith security research. We will not pursue legal action against researchers who:

- Avoid privacy violations, data destruction, and service disruption
- Interact only with their own accounts or accounts they have permission to test
- Do not exploit a vulnerability beyond what is necessary to demonstrate it
- Report promptly and do not disclose publicly before a fix ships
- Do not seek financial gain beyond any bug bounty offered

## Data Sovereignty

AGLedger is self-hosted. All application data — records, receipts, audit logs, API keys — stays within your infrastructure. License validation runs locally with no phone-home.

The Developer Edition (free, unlicensed installs) sends an anonymous heartbeat to `telemetry.agledger.ai` every 48 hours. The heartbeat contains only the running version, uptime, deployment mode, and an anonymous install ID. It contains no application data, no usage metrics, and no identifiers that can be traced to a customer or account. Disable it by setting `AGLEDGER_TELEMETRY=false` in your `.env` file. Enterprise licenses disable telemetry automatically.

Outbound network access is required only for:

- Pulling Docker images during install and upgrade
- Sending the opt-out telemetry heartbeat described above
- Sending support bundles to `support.agledger.ai` when you explicitly run `support-bundle.sh --submit`

For restricted-network deployments, pull images into an internal registry and pass `--image` to `install.sh`. See [air-gap/README.md](air-gap/README.md). Disable telemetry as described above.

## Release Verification

All Docker images and Helm charts are **keyless-signed** with [cosign](https://github.com/sigstore/cosign): GitHub Actions OIDC → Sigstore Fulcio → the **public Rekor** transparency log. There is no static signing key — a valid signature binds to the GitHub Actions workflow that built the release, verifiable against the public Sigstore trust root with no source-repository access. **Requires cosign 3.0 or later.** SBOM (CycloneDX) + OpenVEX attestations and **SLSA Build L3** provenance ship with every release.

```bash
IDENTITY='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
ISSUER='https://token.actions.githubusercontent.com'

# Image (and chart: registry-1.docker.io/agledger/agledger-chart:<version>)
cosign verify --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:<version>

# Attestations
cosign verify-attestation --type cyclonedx --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:<version>
cosign verify-attestation --type openvex   --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:<version>

# SLSA Build L3 provenance (slsa-verifier; pin by digest)
slsa-verifier verify-image "agledger/agledger@$(crane digest agledger/agledger:<version>)" --source-uri github.com/agledger-ai/agledger-api
```

Verification is fully against the public Sigstore trust root — no AGLedger-hosted key or endpoint. The full recipe and per-surface assurance levels (container image = SLSA L3) are in the top-level [README](README.md#verifying-the-release). The signing-key rotation procedure and historical vault keys (the separate audit-chain signing keys) are documented at <https://agledger.ai/trust>.
