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

For sensitive reports, encrypt using the PGP key published at <https://agledger.ai/.well-known/security.txt>.

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

AGLedger is self-hosted. All application data — mandates, receipts, audit logs, API keys — stays within your infrastructure. License validation runs locally with no phone-home.

The Developer Edition (free, unlicensed installs) sends an anonymous heartbeat to `telemetry.agledger.ai` every 48 hours. The heartbeat contains only the running version, uptime, deployment mode, and an anonymous install ID. It contains no application data, no usage metrics, and no identifiers that can be traced to a customer or account. Disable it by setting `AGLEDGER_TELEMETRY=false` in your `.env` file. Enterprise licenses disable telemetry automatically.

Outbound network access is required only for:

- Pulling Docker images during install and upgrade
- Sending the opt-out telemetry heartbeat described above
- Sending support bundles to `support.agledger.ai` when you explicitly run `support-bundle.sh --submit`

For restricted-network deployments, pull images into an internal registry and pass `--image` to `install.sh`. See [air-gap/README.md](air-gap/README.md). Disable telemetry as described above.

## Release Verification

All Docker images and Helm charts are signed with [cosign](https://github.com/sigstore/cosign). The public key is at `cosign.pub` in this repo. SBOM (CycloneDX) and SLSA provenance attestations are attached to each GitHub release.

```bash
cosign verify --key cosign.pub agledger/agledger:<version>
```

The signing-key rotation procedure and historical keys are documented at <https://agledger.ai/trust>.
