# Air-Gapped Installation

`install.sh --image` points the installer at an internal registry instead of Docker Hub. That is the supported air-gap path: pull the image on an internet-connected machine, transfer it, push to your registry, then install.

## Procedure

On a machine with internet access:

```bash
VERSION=1.0.3   # set to the release you're installing
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

## Carry the Postgres image too

A default install runs the bundled Postgres, and that image comes from Docker Hub whatever `--image` says. Save it alongside the release on the connected machine:

```bash
docker pull postgres:18-alpine
docker save postgres:18-alpine | gzip > postgres-18-alpine.tar.gz
```

Load it in the enclave before installing. `--with-monitoring` pulls four more Docker Hub images (OpenTelemetry Collector, Jaeger, Prometheus, Grafana); carry those the same way or leave the flag off. If an image is missing the installer says which one, before it starts anything.

An external database (`--external-db`) needs none of this.

## No registry inside the enclave

The procedure above pushes to an internal registry because the installer pulls before it runs anything. An enclave with no registry at all can install from the local image store instead: load the images and pass `--skip-verify`.

```bash
docker load < agledger-${VERSION}.tar.gz        # the tag-saved bundle from "Procedure" above
docker load < postgres-18-alpine.tar.gz
./scripts/install.sh --version ${VERSION} --skip-verify --non-interactive
```

The flag is required here, and it describes the run accurately. Keyless verification reads the signature from the registry, so an installer that can reach none checks nothing; verify on the connected side and carry the digest, as under [Verifying the Image](#verifying-the-image). Without the flag the installer refuses rather than run bytes it could not check, and it says which image it would not run.

Load the **tag-saved** bundle for this, the one from the Procedure section. A tarball produced by `docker save agledger/agledger@sha256:...` restores as a bare image ID with no repository or tag, and the installer has no name to look up; tag it yourself first, as under Verifying the Image.

`docker load` drops the RepoDigest, so the install records no digest pin and Compose runs `${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}` by tag. The `pull` step reports that it could not reach a registry, finds every image already in the store, and carries on with them.

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

## License Activation

Enterprise license files can be delivered out of band. Place the `.pem` at the configured path (default `/etc/agledger/license.pem`) or set `AGLEDGER_LICENSE_KEY_FILE` to its location. No network access is required for validation.

## Verifying the Image

Releases are **keyless-signed** (cosign → Sigstore/Fulcio → public Rekor). Keyless verification needs reachability to the public Sigstore trust root, so **verify on the internet-connected machine before transferring**, then move the *exact* verified bytes by digest. The image is content-addressed, so a matching digest inside the enclave is, by construction, the bytes you verified: `docker load` validates every layer against the manifest digest.

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
# `docker load` prints "Loaded image ID: sha256:...". A digest-saved image restores
# with no repository or tag, so that ID is the only name it has until you give it one.
LOADED=$(docker load < agledger-${VERSION}.tar.gz | sed 's/.*: //')
docker tag "$LOADED" registry.internal.example.com/agledger:${VERSION}
docker push registry.internal.example.com/agledger:${VERSION}
```

> **Note:** fully *offline* re-verification of the keyless signature inside a disconnected enclave (no Rekor reachability) requires staging the Sigstore trust root out of band and is not part of the supported flow. Verify on the connected side and carry the digest, as above. Track <https://agledger.ai/docs> for changes.
