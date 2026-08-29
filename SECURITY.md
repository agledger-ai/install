# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in AGLedger, report it privately. Do not open a public GitHub issue.

Email **security@agledger.ai** with:

- A description of the vulnerability
- Steps to reproduce
- Impact assessment: what an attacker could achieve
- Affected components (services, endpoints, configurations)
- Environment details: version, deployment method (Compose or Helm), OS, relevant configuration
- Proof of concept: screenshots, logs, or code snippets, if available

If the report is sensitive enough that you do not want the details sitting in plain email, say so
in your first message to **security@agledger.ai** and we will agree an encrypted channel before you
send them.

## Severity and Response

We acknowledge a report promptly and give you an initial assessment as soon as practicable. There
is no fixed clock on those two steps, and we would rather say that than publish a number we cannot
hold to.

A **Security Fix** is a remediation for a vulnerability rated Critical or High under CVSS. Those two
severities carry the release targets stated in the Support Terms:

| Severity | Definition | Release target |
|---|---|---|
| Critical (CVSS 9.0+) | Immediate risk of data breach, auth bypass, or RCE | 7 days |
| High (CVSS 7.0-8.9) | Significant risk requiring prompt attention | 30 days |

These are targets pursued with commercially reasonable effort, not guarantees. Medium and Low
findings are fixed in an ordinary release rather than as a Security Fix, and carry no target date.

**Supported Versions** are the current major version and one prior major version (N and N-1), as
the Support Terms define them, so a deployment does not fall out of the window by being some point
releases behind. The declared **Security Update Support Period** for the Licensed Software is not
less than sixty (60) months from first delivery under an Order Form, or longer where an Order Form
says so.

A Security Fix ships as an ordinary signed release: the image on Docker Hub and the artifacts on
the public GitHub Releases page, neither of which is authenticated or entitlement-gated. There is
no separate security channel to be enrolled in. What each edition is contractually owed is in the
Software License Agreement (§ 6.2) and the Support Terms (§ 5); this file describes how fixes are
built, scanned and published, not who is owed them.

Our coordinated vulnerability disclosure policy asks for a 90-day window: please do not disclose
publicly before a fix is available or 90 days have passed, whichever comes first. For anything under
active exploitation we move faster and coordinate an accelerated timeline with you, and we are glad
to coordinate CVE assignment and a joint disclosure.

You will be kept informed of progress and credited in the advisory unless you ask to remain anonymous.

## Safe Harbor

AGLedger supports good-faith security research. We will not pursue legal action against researchers who:

- Avoid privacy violations, data destruction, and service disruption
- Interact only with their own accounts or accounts they have permission to test
- Do not exploit a vulnerability beyond what is necessary to demonstrate it
- Report promptly and do not disclose publicly before a fix ships
- Do not seek financial gain beyond any bug bounty offered

## Data Sovereignty

AGLedger is self-hosted. All application data (records, receipts, audit logs, API keys) stays within your infrastructure. There is no telemetry and no phone-home of any kind: license validation runs locally, and the Server never reports back to AGLedger at runtime.

Outbound network access is required only for:

- Pulling Docker images during install and upgrade
- Sending a support bundle to `support.agledger.ai` (`AGLEDGER_SUPPORT_BUNDLE_URL`), and only when you explicitly upload one via `POST /v1/admin/support-bundle/upload`. `./scripts/support-bundle.sh` writes a local tarball and sends nothing

For restricted-network deployments, pull images into an internal registry and pass `--image` to `install.sh`. See [air-gap/README.md](air-gap/README.md).

## What we build and scan

**OpenSSF-aligned supply chain.** SLSA Build L3 provenance, Sigstore keyless
signing, and SBOM + OpenVEX + malware-scan attestations, all verifiable offline
with no repository access.

Every release is built by GitHub Actions, and **no signing key exists on any build
machine.** Trust flows from GitHub's OIDC identity → Sigstore Fulcio (an ephemeral
certificate) → the **public Rekor** transparency log. A valid signature proves the
artifact was produced by *our* release workflow at a tagged commit, and it is
verifiable against the public Sigstore trust root with **no access to the source
repository**.

Before an image is published, the release pipeline runs two **blocking** gates
against the exact bytes being shipped. A failure on either stops the release, so a
flagged image never reaches the registry:

- **CVE scan** (Trivy, CRITICAL/HIGH, fixable): known-vulnerable OS and
  dependency versions. Reviewed exceptions for unfixable upstream CVEs are tracked
  in an attested OpenVEX document.
- **Known-malware scan** (ClamAV): signature scan of the image's shipping
  filesystem, with a built-in positive control that fails the build if the signature
  database is missing or stale (so a "clean" result can never be a no-op). This is
  the layer CVE scanning is blind to: a compromised or typosquatted dependency that
  injects a payload has no CVE.

Source code is additionally checked by Semgrep (SAST) before each release and by
Dependabot (dependency updates) continuously.

## Release Verification

**Requires cosign 3.0 or later** (and `slsa-verifier`, `crane`, and `jq` for the
provenance and malware-scan steps). Every command below verifies against the public
Sigstore trust root, with no AGLedger-hosted key or endpoint and no repository access.

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
#     the predicate TYPE, not the field values. Assert the result yourself:
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
packages, npm (`@agledger/*`, `npm --provenance`), are **SLSA Build L2**; PyPI
(`agledger`, Trusted Publishing / PEP 740) ships **signed publish attestations**
(not a numbered SLSA level). All share the same GitHub-OIDC → Sigstore trust root.
L3 is the level at which build provenance becomes non-falsifiable: the assurance
the image carries, and the property every command above verifies.

The SBOM, OpenVEX document, and the signed conformance corpus are attached to every
[GitHub Release on this public repo](https://github.com/agledger-ai/install/releases)
for direct download (`agledger-<version>-sbom.cdx.json`,
`agledger-<version>-vex.openvex.json`, `agledger-<version>-conformance-corpus.tar.gz`
+ `.sha256` + `.sigstore.json`). The release signing above is keyless: there is no
long-lived signing key to steal, rotate or revoke, and nothing outside a run of our release workflow
can obtain a certificate for that identity. It is not a defence against a runner compromised while
that job is running, which holds the OIDC token the job was issued: the isolated SLSA Build L3
builder and the public transparency log are what address build-machine compromise. The separate audit-chain (vault) signing keys, the ones your own Server holds, are
published live at `GET /.well-known/agledger-vault-keys.json` and `GET /v1/verification-keys`.

## Mirrored registries (AWS Marketplace / ECR)

`agledger/agledger` on Docker Hub is the authoritative artifact. It carries the
Sigstore signature and the SBOM / OpenVEX / malware-scan / SLSA L3 attestations, and
it's where every command above runs. The **AWS Marketplace** delivery (and any other
ECR mirror) is a **byte-identical copy of that image, the same digest**, but the
Sigstore artifacts are intentionally **not** carried into ECR, because AWS
Marketplace requires a plain image manifest and rejects attestation artifacts.

So provenance for a Marketplace pull is established by **digest equality**: verify the
authoritative Docker Hub image, then confirm the Marketplace image is the same bytes.

```bash
# 1. Verify the authoritative public image (signature + SLSA L3, as above) and note
#    its digest. This is the artifact that carries the full provenance.
DH_DIGEST=$(crane digest agledger/agledger:<version>)
echo "$DH_DIGEST"

# 2. Confirm the AWS Marketplace image is the identical digest.
aws ecr describe-images \
  --registry-id 709825985650 --repository-name ag-ledger/agledger \
  --image-ids imageTag=<version> --region us-east-1 \
  --query 'imageDetails[0].imageDigest' --output text
# → must equal $DH_DIGEST
```

If the two digests match, the Marketplace image is the same bytes as the
cryptographically verified public image, and inherits its full provenance.

## If your vault signing key is compromised

The full runbook is [Signing-key compromise](https://agledger.ai/docs/operations/key-compromise).
The semantics it turns on, so you can plan against them before you need it:

- **Rotation is the containment step, and a restart is what performs it.** On boot the Server
  reconciles the key registry to the configured `VAULT_SIGNING_KEY`: it activates that key and
  retires the previous one with a `retiredAt` instant.
  `POST /v1/admin/vault/signing-keys/rotate` runs the same reconciliation on demand and answers
  `already_active` against a Server that has already restarted.
- **There is no revocation, by design.** A key is `active` or `retired`; there is no `compromised`
  status, and a retired key keeps verifying the entries it signed. That is what makes routine
  rotation non-destructive, and it means the product will not mark records signed inside your
  compromise window. Rotation stops future signing with that key; it says nothing about what was
  signed before it.
- **External anchors are what bound the window.** Anchors written to Object Lock storage before the
  exposure are ground truth an attacker holding the key could not rewrite, so they split your
  history into a span that is provably intact and a span you have to corroborate from outside the
  chain. Turn anchoring on (`VAULT_ANCHOR_ENABLED=true`; `VAULT_ANCHOR_INTERVAL_MINUTES` sets the
  cadence, default 360) before you need it, because enabling it during an incident bounds nothing
  already written.
