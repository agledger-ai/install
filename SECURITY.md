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

The Developer Edition (free, unlicensed installs) can send an anonymous heartbeat to `telemetry.agledger.ai` every 48 hours, but it is **opt-in and off by default** — nothing is sent unless you explicitly set `AGLEDGER_TELEMETRY=true` in your `.env` file. When enabled, the heartbeat contains only the running version, uptime, deployment mode, and an anonymous install ID. It contains no application data, no usage metrics, and no identifiers that can be traced to a customer or account. Enterprise licenses never send telemetry.

Outbound network access is required only for:

- Pulling Docker images during install and upgrade
- Sending the opt-out telemetry heartbeat described above
- Sending support bundles to `support.agledger.ai` when you explicitly run `support-bundle.sh --submit`

For restricted-network deployments, pull images into an internal registry and pass `--image` to `install.sh`. See [air-gap/README.md](air-gap/README.md). Disable telemetry as described above.

## What we build and scan

**OpenSSF-aligned supply chain** — SLSA Build L3 provenance, Sigstore keyless
signing, and SBOM + OpenVEX + malware-scan attestations, all verifiable offline
with no repository access.

Every release is built by GitHub Actions — **no signing key exists on any build
machine.** Trust flows from GitHub's OIDC identity → Sigstore Fulcio (an ephemeral
certificate) → the **public Rekor** transparency log. A valid signature proves the
artifact was produced by *our* release workflow at a tagged commit, and it is
verifiable against the public Sigstore trust root with **no access to the source
repository**.

Before an image is published, the release pipeline runs two **blocking** gates
against the exact bytes being shipped — a failure on either stops the release, so a
flagged image never reaches the registry:

- **CVE scan** (Trivy, CRITICAL/HIGH, fixable) — known-vulnerable OS and
  dependency versions. Reviewed exceptions for unfixable upstream CVEs are tracked
  in an attested OpenVEX document.
- **Known-malware scan** (ClamAV) — signature scan of the image's shipping
  filesystem, with a built-in positive control that fails the build if the signature
  database is missing or stale (so a "clean" result can never be a no-op). This is
  the layer CVE scanning is blind to: a compromised or typosquatted dependency that
  injects a payload has no CVE.

Source code is additionally checked by Semgrep (SAST) before each release and by
Dependabot (dependency updates) continuously.

## Release Verification

**Requires cosign 3.0 or later** (and `slsa-verifier`, `crane`, and `jq` for the
provenance and malware-scan steps). Every command below verifies against the public
Sigstore trust root — no AGLedger-hosted key or endpoint, no repository access.

```bash
IDENTITY='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
ISSUER='https://token.actions.githubusercontent.com'

# 1. Image signature (signing the digest covers :<version> and :latest)
cosign verify --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger/agledger:<version>

# 2. Helm chart signature
cosign verify --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  registry-1.docker.io/agledger/agledger-chart:<version>

# 3. Attestations bound to the image: SBOM (CycloneDX), OpenVEX, malware-scan
cosign verify-attestation --type cyclonedx --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:<version>
cosign verify-attestation --type openvex   --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:<version>

# 3a. Malware-scan result. IMPORTANT: verify-attestation checks the signature and
#     the predicate TYPE — not the field values. Assert the result yourself:
cosign verify-attestation --type https://agledger.ai/attestations/malware-scan/v1 \
  --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger/agledger:<version> \
  | jq -e '.payload | @base64d | fromjson | .predicate.result == "no-detections"' >/dev/null \
  && echo "malware scan: no detections"

# 4. SLSA Build L3 provenance (non-falsifiable; isolated builder, posted to public Rekor)
slsa-verifier verify-image "agledger/agledger@$(crane digest agledger/agledger:<version>)" \
  --source-uri github.com/agledger-ai/agledger-api \
  --builder-id 'https://github.com/slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@refs/tags/v2.1.0'

# 5. Verifier conformance corpus (a release asset). The .sha256 proves integrity;
#    the Sigstore bundle proves it is genuinely FROM AGLedger and unchanged:
cosign verify-blob \
  --bundle agledger-<version>-conformance-corpus.tar.gz.sigstore.json \
  --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger-<version>-conformance-corpus.tar.gz
```

**Per-surface assurance:** the container image is **SLSA Build L3**. The public
packages — npm (`@agledger/*`, `npm --provenance`) — are **SLSA Build L2**; PyPI
(`agledger`, Trusted Publishing / PEP 740) ships **signed publish attestations**
(not a numbered SLSA level). All share the same GitHub-OIDC → Sigstore trust root.
L3 is the level at which build provenance becomes non-falsifiable — the assurance
the image carries, and the property every command above verifies.

The SBOM, OpenVEX document, and the signed conformance corpus are attached to every
[GitHub Release on this public repo](https://github.com/agledger-ai/install/releases)
for direct download (`agledger-<version>-sbom.cdx.json`,
`agledger-<version>-vex.openvex.json`, `agledger-<version>-conformance-corpus.tar.gz`
+ `.sha256` + `.sigstore.json`). The signing-key rotation procedure is documented at
<https://agledger.ai/docs>; the separate audit-chain (vault) signing keys are
published live at `GET /.well-known/agledger-vault-keys.json` and
`GET /v1/verification-keys`.
