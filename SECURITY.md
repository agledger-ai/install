# Security Policy

## Reporting a Vulnerability

Report privately. Do not open a public GitHub issue.

- Email **security@agledger.ai**, or
- Use GitHub private vulnerability reporting on the public install repository:
  [Report a vulnerability](https://github.com/agledger-ai/install/security/advisories/new).

Please include the affected component and version (and image digest, if applicable), what an
attacker could achieve, steps to reproduce, and your deployment details (version, deployment
method, OS, relevant configuration). If a report is sensitive enough that you do not want the
detail sitting in plain email, say so in your first message and we will agree an encrypted
channel with you before you send it.

Scope, the safe harbor for good-faith security research, and the coordinated disclosure timeline
are published in the AGLedger Coordinated Vulnerability Disclosure Policy at
<https://agledger.ai/security>. That page is the policy. This file describes how releases are
built, scanned and verified.

## Supported Versions

Supported Versions are the current major version and one prior major version (N and N-1), as
defined in the Support Terms. The Security Update Support Period, and what each edition is
contractually owed, are stated in the Software License Agreement published at
<https://agledger.ai/license> (sections 6.2 and 6.4) and in the Support Terms.

A Security Fix ships as an ordinary signed release: the image on Docker Hub and the artifacts on
the public GitHub Releases page, neither of which is authenticated or entitlement-gated. There is
no separate security channel to be enrolled in.

## Data Sovereignty

AGLedger is self-hosted. All application data (records, receipts, audit logs, API keys) stays within your infrastructure. There is no telemetry, and the Server never reports usage back to AGLedger at runtime. A license key issued to you directly is validated locally by signature check, with no network call at all.

Outbound network access is required only for:

- Pulling Docker images during install and upgrade
- Sending a support bundle, and only on a deployment where you have set `AGLEDGER_SUPPORT_BUNDLE_URL` to an upload target of your own and then upload one via `POST /v1/admin/support-bundle/upload`. That variable has no default, so with it unset nothing is ever uploaded. The documented path is `./scripts/support-bundle.sh`, which makes no network call: it writes a local tarball you review and send to support@agledger.ai
- Destinations you configure yourself, each off until you set it: webhook receivers, federation peers, your IdP's discovery and JWKS endpoints, the S3 bucket external anchors are written to, the SIEM collector, and an OTLP collector for telemetry export
- Checking your marketplace entitlement, on a marketplace install only. Setting `AWS_MARKETPLACE_PRODUCT_ID` turns on an AWS License Manager `CheckoutLicense` call every 15 minutes. Startup and `POST /v1/admin/license/reload` reach that same call only when you have configured no license key of your own, because a key you hold is read first and settles the tier locally with no network at all. The call goes to AWS, not to AGLedger, and carries no record, agent, or usage data: the request names the product, a key fingerprint, and a count of one. It fails open, so an unreachable entitlement service never blocks or degrades anything. Leave the variable unset and no such call is ever made

For restricted-network deployments, pull images into an internal registry and pass `--image` to `install.sh`. See [air-gap/README.md](air-gap/README.md).

## Data retention and erasure

The engine runs no retention job over the chain, and there is no retention knob.
`audit_vault`, `events`, `webhook_deliveries` and `system_audit_log` are range-partitioned by
month. Partitions are created ahead of the clock and nothing detaches or drops one, so those
tables grow for the life of the install. Sizing and archival are yours: snapshot, back up or
detach partitions with your own tooling. `audit_vault` refuses a row `DELETE` or `UPDATE`
outright, and a `TRUNCATE` or a partition drop is refused unless the session sets
`agledger.allow_audit_drop`, so an accidental prune is not available either. The partition-drop
half of that guard is a `sql_drop` event trigger, which Postgres only lets a superuser create: on
a managed database whose migrate role has no superuser-equivalent grant, it is absent and the
row-level and `TRUNCATE` guards are what remain.

There is no erasure endpoint. A record, its chain entries and its events cannot be deleted
through the API.

Scheduled sweeps delete only short-lived operational rows. None of them carries record content:

| Table | What the sweep removes |
|---|---|
| `idempotency_keys` | expired keys, plus in-flight claims a crashed request left behind |
| `oidc_consumed_jtis` | rows whose admin bearer token has expired |
| `rate_limits` | expired windows, and only when `RATE_LIMIT_STORE=postgresql` |
| `federation_nonces` | replay-protection nonces past their window |
| `federation_idempotency` | the peer request/response cache past its window |
| pg-boss job tables | completed jobs, under pg-boss's own retention |

Webhook signing secrets are a column rather than a row: the rotation sweep clears
`previous_secret` once the grace window closes.

## Encrypted mode: what is sealed, and what destroying the key does

Encrypted mode (`operatingMode: "encrypted"` on a record) seals completion evidence under a key
you hold. The Server holds no decryption key and no key material for it. Your writer encrypts
before submission; the envelope's `kid` is your own label for the key, stored as given and never
resolved against anything.

| Field | Encrypted mode | What the Server holds |
|---|---|---|
| Completion `evidence` | Sealed | The AES-256-GCM envelope as submitted. `enc`, `iv` and `tag` are stored and served verbatim and the Server never decrypts them. `kid` is the writer's own key label, stored as given. |
| `evidenceHash` | Plaintext | The writer's SHA-256 over the cleartext, signed into the COMPLETION_SUBMITTED chain entry. It binds the sealed bytes to what the principal verdicted on. |
| `evidence.declaredContext` | Plaintext | The envelope-to-record binding, signed into the chain entry so an auditor can check it offline. |
| `criteria` | Plaintext | Server-readable by design: tolerance evaluation, `?criteria[key]=` search and the signed payload of every record-state chain entry all carry it verbatim. To keep a criteria value off the Server, commit to it off-record and store a hash. |
| `humanOversight` | Plaintext | Free-form text, stored and served as written. It stays intra-org: no federation projection carries it. |
| `metadata` | Plaintext | Unsigned annotation, served as written and never carried in the signed chain payload. |
| `orgId`, `principalAgentId`, `performerAgentId` | Plaintext | The identity attestation. Signed into the chain and used for authorization, so encryption never covers it. |
| `type`, `contractVersion`, `platform` | Plaintext | The registered Type the record was written against. Encrypted mode skips completion-schema validation but still records which Type was claimed. |
| Timestamps and chain position | Plaintext | The time and order attestations: `createdAt`, the per-transition times, and each chain entry's position and hash links. |
| `status`, `verdict`, Settlement Signal | Plaintext | The acceptance attestation. The principal decrypts off-server and renders the verdict; what lands on the chain is the decision, never the evidence it was based on. |

The federation projection is narrower than any of it: a peer receives no evidence at all, sealed
or otherwise, and `criteria` crosses as `{}`.

Destroying your key renders the sealed evidence unreadable. Nothing on the Server changes,
because the Server never held the key, and the observable result is:

- Reads keep succeeding. The completion endpoints and `GET /v1/records/{id}/audit-export?evidence=true`
  return 200 with the envelope verbatim. No read fails, and no read returns cleartext.
- The chain entry, its hash and its signature stay verifiable. `chainIntegrity` stays `true`,
  `integrityLevel` and `signatureCoverage` are unchanged, and the audit export stays complete.
  The chain commits to `evidenceHash`, `declaredContext` and the state transitions, never to the
  ciphertext and never to the cleartext.
- Everything in the Plaintext column above stays readable, `criteria` included.
- What is lost is re-binding. `verificationGuide.evidenceBinding` tells a verifier to re-derive
  `evidenceHash` from the cleartext, and with the key gone nobody can produce that cleartext. The
  signed hash remains, so the record still attests that evidence with that digest existed and was
  accepted or rejected at that position in the chain.

## What we build and scan

**OpenSSF-aligned supply chain.** SLSA Build L3 provenance, Sigstore keyless
signing, and SBOM + OpenVEX + malware-scan attestations, all verifiable with no
repository access and no AGLedger-hosted endpoint.

Every release is built by GitHub Actions, and **no signing key exists on any build
machine.** Trust flows from GitHub's OIDC identity → Sigstore Fulcio (an ephemeral
certificate) → the **public Rekor** transparency log. A valid signature proves the
artifact was produced by *our* release workflow at a tagged commit, and it is
verifiable against the public Sigstore trust root with **no access to the source
repository**.

Before an image is published, the release pipeline runs four **blocking** gates
against the exact bytes being shipped. A failure on any one stops the release, so a
flagged image never reaches the registry:

- **CVE scan** (Trivy, CRITICAL/HIGH, fixable), on both arches: known-vulnerable OS
  and dependency versions. Reviewed exceptions for unfixable upstream CVEs are tracked
  in an attested OpenVEX document.
- **Known-malware scan** (ClamAV): signature scan of the image's shipping
  filesystem, with a built-in positive control that fails the build if the signature
  database is missing or unusable (so a "clean" result can never be a no-op; a database
  that is old but intact still passes it). This is
  the layer CVE scanning is blind to: a compromised or typosquatted dependency that
  injects a payload has no CVE.
- **Boot gate**, on both arches: the image runs migrations against a real PostgreSQL
  and must serve `/health`, `/llms.txt` and `/v1/verification-keys`.
- **FIPS boot gate**, on amd64: the same image boots with the base image's FIPS
  provider active and must serve on the ES256 signing path, refuse federation keys,
  and refuse to boot with `AGLEDGER_FIPS=true` and no active provider. This gate
  tests provider behaviour rather than arch parity, which the boot gate above
  already covers on both arches.

Source code is additionally checked by Semgrep (SAST) before each release and by
Dependabot (dependency updates) continuously.

## Release Verification

**Requires cosign 3.0 or later** (the install scripts check that `cosign` is present, not its version; an older cosign fails on the bundle format rather than passing silently) (and `slsa-verifier`, `crane`, and `jq` for the
provenance and malware-scan steps). Every command below verifies against the public
Sigstore trust root, with no AGLedger-hosted key or endpoint and no repository access.
Each reads the signature from the registry and the trust root over the network; a
host that can reach neither verifies the same release from carried material, with
`scripts/verify-release.sh` and the release's
`agledger-<version>-offline-verification.tar.gz`. See
[air-gap/README.md](air-gap/README.md).

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
+ `.sha256` + `.sigstore.json`), alongside
`agledger-<version>-offline-verification.tar.gz` + `.sha256` + `.sigstore.json`,
which carries the signature and attestation bundles and the Sigstore trust root
for a host with no network. That archive is the trust anchor an air-gapped check
hangs from, so verify its own `cosign verify-blob` while a network is still
reachable, before carrying it in. The release signing above is keyless: there is no
long-lived signing key to steal, rotate or revoke, and nothing outside a run of our release workflow
can obtain a certificate for that identity. It is not a defence against a runner compromised while
that job is running, which holds the OIDC token the job was issued: the isolated SLSA Build L3
builder and the public transparency log are what address build-machine compromise. The separate audit-chain (vault) signing keys, the ones your own Server holds, are
published live at `GET /.well-known/agledger-vault-keys.json` and `GET /v1/verification-keys`.
Those surfaces publish only keys a signed key statement links to a key held outside the database;
a key row written with database access alone is not published and verifies nothing. The pin the
installer prints (`Pin: sha256:<hex>`, the SHA-256 of the key's SPKI DER) is the value to hand an
auditor, and the high-assurance input for offline verification once the verifier walks key
statements; `node dist/scripts/signing-key-digest.js` derives it again.

## Mirrored registries (AWS Marketplace / ECR)

`agledger/agledger` on Docker Hub is the authoritative artifact. It carries the
Sigstore signature and the SBOM / OpenVEX / malware-scan / SLSA L3 attestations, and
it's where every command above runs. The **AWS Marketplace** delivery (and any other
ECR mirror) is a **byte-identical copy of the linux/amd64 platform image**, but the
Sigstore artifacts are intentionally **not** carried into ECR, because AWS
Marketplace requires a plain image manifest and rejects attestation artifacts. Docker
Hub publishes `:<version>` as a multi-arch index; Marketplace holds that index's
linux/amd64 child, so the digest to compare is the child's, not the index's.

So provenance for a Marketplace pull is established by **digest equality**: verify the
authoritative Docker Hub image, then confirm the Marketplace image is the same bytes.

```bash
# 1. Verify the authoritative public image (signature + SLSA L3, as above) and note
#    the digest of its linux/amd64 platform manifest. The signature covers the index,
#    and the index names this digest.
DH_AMD64_DIGEST=$(crane digest --platform linux/amd64 agledger/agledger:<version>)
echo "$DH_AMD64_DIGEST"

# 2. Confirm the AWS Marketplace image is that manifest.
aws ecr describe-images \
  --registry-id 709825985650 --repository-name ag-ledger/agledger \
  --image-ids imageTag=<version> --region us-east-1 \
  --query 'imageDetails[0].imageDigest' --output text
# → must equal $DH_AMD64_DIGEST
```

If the two digests match, the Marketplace image is the same bytes as the
cryptographically verified public image's linux/amd64 manifest, and inherits its
provenance. `scripts/mirror-ecr.sh` makes the same comparison after every mirror and
fails when they differ.

## Where the vault signing key lives

Two custody options, chosen per install:

- **Key material in the process environment** (`VAULT_SIGNING_KEY`, or a file through
  `VAULT_SIGNING_KEY_FILE`, or SSM through `SECRETS_PROVIDER=aws-ssm`). The default. The private key
  is in the container's environment and in whatever Secret or file supplied it, and anyone who can
  read either can sign as this Server.
- **AWS KMS** (`VAULT_SIGNING_KEY_KMS_ARN`; on Helm, `signing.kmsKeyArn`). The private half is a
  non-exportable ECC_NIST_P256 key in KMS. The Server fetches the public half at boot, registers it
  in `vault_signing_keys` under the same fingerprint scheme as a local key, and every signature is
  one KMS `Sign` call: chain entries, checkpoints, Receipts, the DSSE attestation bundle, SCITT tree
  heads, RFC 9421 webhook deliveries and ephemeral-certificate JWS all take the KMS key; no signing
  site keeps a local one. Who can sign as this Server is then the KMS key policy and CloudTrail
  records every use. KMS signs no Ed25519, so this is an ES256 chain and takes the same
  `AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true` opt-in as a local ES256 key; upgrade the verifiers
  first.

What KMS custody changes operationally, and what it does not:

- Rotation and retirement are the same two steps, and the new key needs its predecessor to sign
  a succession. Moving from a local key: set the ARN, move the local key to
  `VAULT_SIGNING_KEY_PREVIOUS` and unset `VAULT_SIGNING_KEY` (it and the ARN together refuse to
  boot). Moving from one KMS key to another: set the new ARN and
  `VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN` (`signing.previousKmsKeyArn` on Helm) to the old one, with
  `kms:GetPublicKey` and `kms:Sign` on both keys for the change; the old key never leaves KMS and
  signs only the succession. The two `PREVIOUS` variables together refuse to boot. Retirement is
  `POST /v1/admin/vault/signing-keys/{keyId}/retire`, sent to a process on the new key.
- When KMS does not answer, the Server fails closed. A write whose `Sign` call fails is rolled back
  and answered 503 (`/problems/signing-key-unusable`) with a `recoveryHint` naming what to check.
  After consecutive failures the process stops trying: `/health/ready` answers 503 with
  `signingKey.gate` `signer_unreachable`, so a load balancer routes around it, and the worker
  holds the jobs it has fetched rather than failing them. Every signing-key watch tick then makes
  one probe `Sign`, and the first answered one resumes writing; nothing needs restarting. The
  shipped alert rules (`AGLedgerVaultSignerUnreachable`, `AGLedgerVaultRemoteSignFailing`) and the
  `agledger_vault_remote_sign_seconds` histogram are the operator's view of it.
- Rate: one `Sign` per signature, plus one probe `Sign` per api and worker process each signing-key
  watch interval, and KMS `Sign` quotas are per account and region, shared with every
  other caller of that key type. `VAULT_SIGNING_REMOTE_MAX_PER_SECOND` caps each process; the sum
  across api and worker replicas has to sit under the quota.
- The federation identity key and the license key are separate signing domains and stay where they
  were; custody covers the vault key only.

`GET /v1/admin/vault/signing-keys` reports which backend the answering process signs with
(`signer.backend`), since the registry rows themselves do not record custody.

## If your vault signing key is compromised

The full runbook is [Signing-key compromise](https://agledger.ai/docs/operations/key-compromise).
The semantics it turns on, so you can plan against them before you need it:

- **A key is trusted only through a statement signed by a key held outside the database.** A
  new key is admitted by a succession statement signed by it and its predecessor, so the process
  that stages it runs with `VAULT_SIGNING_KEY_PREVIOUS` set to the key in use; a new key with no
  predecessor signer registers nothing and signs nothing (`signingKey.gate: "unanchored"`). A key
  row planted with database access alone verifies nothing: entries it signs break as
  `signing_key_unanchored` and no public key surface lists it.
- **Containment is two steps: restart, then retire.** A process that boots with a new
  `VAULT_SIGNING_KEY` and the current key as `VAULT_SIGNING_KEY_PREVIOUS` registers it and starts
  signing with it, retiring nothing, so more than one key is active while you roll.
  `POST /v1/admin/vault/signing-keys/rotate` performs the same registration on demand and answers
  `already_active` against a process that has already restarted. Closing the leaked key's window is
  `POST /v1/admin/vault/signing-keys/{keyId}/retire` from a process on the new key, and on a
  compromise you send `{"force": true}` rather than waiting for processes to roll. The retirement
  writes a closure statement, signed by the new key; a forced one voids every edge out of the leaked
  key, to the keys it admitted and back to its predecessor, and the keys that leaves unanchored are listed in `unanchoredKeyIds` (retired,
  certificates revoked, their entries reported as `signing_key_unanchored`). An honest key among
  them is re-anchored through `VAULT_TRUST_ANCHORS`, followed by an unforced retire call where the
  scan reports `key_closure_invalid` for it, a process on one restarts on a fresh key, and auditors take
  the pin of the key that ran the retirement plus every pin added to `VAULT_TRUST_ANCHORS`: a pin on
  the current key no longer reaches the history behind the leaked key.
  Closures the leaked key signs still apply, and only take trust away: at worst they shorten a
  key's window, which is a denial of service, never a key trusted, but one nothing in the database
  undoes (a closure dated before the current key's activation expires all it signed). Its pin in
  `VAULT_DISTRUSTED_KEYS` on every process, optionally `@<instant>` for when it leaked, makes what
  it signs from that instant, or from its retirement, count for nothing; the forced retirement's
  response names the entry. The same applies to a key retired on schedule that leaks later. With no successor you trust, set
  `VAULT_TRUST_ANCHORS` to the pins of the keys whose history you vouch for and restart; the new
  key registers under a fresh genesis and auditors take its pin. Nothing inside the database can
  tell your successor from an attacker's. Chain appends under that key stop
  the instant the retirement commits, because an append and the retirement take the same row lock.
  The other signers (RFC 9421 webhook deliveries, ephemeral-certificate JWS, Receipts) stop when
  the process notices: at once on an api process, within 30 seconds on a worker, which re-reads the
  registry on that interval. A process that has noticed fails its readiness probe and, on the
  worker, stops consuming jobs. Anything signed with the leaked key afterwards falls outside its
  published window: a chain scan reports `key_expired` and an offline verifier reports
  `CHAIN_KEY_EXPIRED`. On a scheduled rotation you confirm instead that every api and worker
  process reports the new key on its own `/health` (`signingKey.keyId`); the 422 the endpoint
  answers while the old key has appended inside the last 300 seconds is a backstop for the case
  the chain can see, and an idle process passes it while still holding the key. Both orders are in
  `deploy/README.md` under "Changing the signing key".
- **There is no revocation of what a key signed, by design.** A key is `active` or `retired`;
  there is no `compromised` status, and a retired key keeps verifying the entries it signed inside
  its published window
  (`activatedAt` to `retiredAt`), both on this Server and in `@agledger/verify`. That is what makes routine
  rotation non-destructive, and it means the product will not mark records signed inside your
  compromise window. Rotation stops future signing with that key; it says nothing about what was
  signed before it.
- **External anchors are what bound the window.** Anchors are written create-only (`If-None-Match`)
  and, under Object Lock, as versions nothing can delete; a second write to an anchored position is
  refused and reported as a fork, and a store that does not honour conditional writes is named in
  the anchor posture (`GET /v1/admin/vault/anchors/reconcile`). Anchors written before the exposure
  are therefore ground truth an attacker holding the key cannot rewrite, so they split your
  history into a span that is provably intact and a span you have to corroborate from outside the
  chain. Turn anchoring on (`VAULT_ANCHOR_ENABLED=true`; `VAULT_ANCHOR_INTERVAL_MINUTES` sets the
  cadence, default 360) before you need it, because enabling it during an incident bounds nothing
  already written.
