# Air-Gapped Installation

`install.sh --image` points the installer at an internal registry instead of Docker Hub. That is the supported air-gap path — pull the image on an internet-connected machine, transfer it, push to your registry, then install.

## Procedure

On a machine with internet access:

```bash
VERSION=0.27.5   # set to the release you're installing
docker pull agledger/agledger:${VERSION}
docker save agledger/agledger:${VERSION} | gzip > agledger-${VERSION}.tar.gz
```

Also grab this repo (scripts, compose files, Helm chart):

```bash
git clone --depth 1 https://github.com/agledger-ai/install.git
tar czf install.tar.gz install/
```

Transfer `agledger-${VERSION}.tar.gz` and `install.tar.gz` to your air-gapped environment.

Inside the air-gapped environment, load the image and push it to your internal registry:

```bash
docker load < agledger-${VERSION}.tar.gz
docker tag agledger/agledger:${VERSION} registry.internal.example.com/agledger:${VERSION}
docker push registry.internal.example.com/agledger:${VERSION}
```

Run the installer against your registry:

```bash
tar xzf install.tar.gz
cd install
./scripts/install.sh \
  --image registry.internal.example.com/agledger \
  --version ${VERSION} \
  --non-interactive
```

## Helm Chart

The Helm chart is published to OCI at `oci://registry-1.docker.io/agledger/agledger-chart`. To air-gap it:

```bash
helm pull oci://registry-1.docker.io/agledger/agledger-chart --version ${VERSION}
# transfer the resulting agledger-chart-${VERSION}.tgz
helm install agledger agledger-chart-${VERSION}.tgz \
  --set image.repository=registry.internal.example.com/agledger \
  --set image.tag=${VERSION} \
  --values your-values.yaml
```

## Telemetry

Developer Edition sends an anonymous heartbeat to `telemetry.agledger.ai` every 48 hours. In a restricted-network environment this call will fail and log a warning; it has no effect on runtime behavior. Set `AGLEDGER_TELEMETRY=false` in `.env` to disable it cleanly. Enterprise licenses disable it automatically.

## License Activation

Enterprise license files can be delivered out of band. Place the `.pem` at the configured path (default `/etc/agledger/license.pem`) or set `AGLEDGER_LICENSE_KEY_FILE` to its location. No network access is required for validation.

## Verifying the Image

Releases are **keyless-signed** (cosign → Sigstore/Fulcio → public Rekor). Keyless verification needs reachability to the public Sigstore trust root, so **verify on the internet-connected machine before transferring**, then move the *exact* verified bytes by digest. The image is content-addressed, so a matching digest inside the enclave is, by construction, the bytes you verified — `docker load` validates every layer against the manifest digest.

On the internet-connected machine (full recipe in the top-level [README](../README.md#verifying-the-release)):

```bash
IDENTITY='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
ISSUER='https://token.actions.githubusercontent.com'
cosign verify --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" agledger/agledger:${VERSION}

# Capture the verified digest and save THAT (not a mutable tag):
DIGEST=$(crane digest agledger/agledger:${VERSION})
echo "$DIGEST" > agledger-${VERSION}.digest
docker save "agledger/agledger@${DIGEST}" | gzip > agledger-${VERSION}.tar.gz
```

Transfer `agledger-${VERSION}.tar.gz` and `agledger-${VERSION}.digest`. In the enclave, load and pin the install to that digest (a successful `docker load` of the digest-saved image is the integrity check):

```bash
docker load < agledger-${VERSION}.tar.gz
docker tag "agledger/agledger@$(cat agledger-${VERSION}.digest)" registry.internal.example.com/agledger:${VERSION}
docker push registry.internal.example.com/agledger:${VERSION}
```

> **Note:** fully *offline* re-verification of the keyless signature inside a disconnected enclave (no Rekor reachability) requires staging the Sigstore trust root out of band and is not part of the supported flow — verify on the connected side and carry the digest, as above. Track <https://agledger.ai/trust> for changes.
