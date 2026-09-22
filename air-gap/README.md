# Air-Gapped Installation

`install.sh --image` points the installer at an internal registry instead of Docker Hub. That is the supported air-gap path: pull the image on an internet-connected machine, transfer it, push to your registry, then install.

## Procedure

On a machine with internet access:

```bash
VERSION=X.Y.Z   # the release you are installing
docker pull agledger/agledger:${VERSION}
docker save agledger/agledger:${VERSION} | gzip > agledger-${VERSION}.tar.gz

# What verifies that image inside the enclave. See "Verifying the Image" below.
R=https://github.com/agledger-ai/install/releases/download/v${VERSION}
curl -fsSLO $R/agledger-${VERSION}-offline-verification.tar.gz \
     -O $R/agledger-${VERSION}-offline-verification.tar.gz.sha256 \
     -O $R/agledger-${VERSION}-offline-verification.tar.gz.sigstore.json

# Check it HERE, while Sigstore is reachable. This archive carries the trust
# anchor every check inside the enclave reads, so it is the one file whose own
# authorship has to be established on this side of the gap.
IDENTITY='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
ISSUER='https://token.actions.githubusercontent.com'
cosign verify-blob \
  --bundle agledger-${VERSION}-offline-verification.tar.gz.sigstore.json \
  --certificate-identity-regexp "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  agledger-${VERSION}-offline-verification.tar.gz
```

Also grab this repo (scripts, compose files, Helm chart):

```bash
git clone --depth 1 --branch v${VERSION} https://github.com/agledger-ai/install.git
tar czf install.tar.gz install/
```

Transfer those four files to your air-gapped environment.

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

## Verifying the Image

Releases are **keyless-signed** (cosign → Sigstore/Fulcio → public Rekor), and that signature is verifiable inside the enclave, against material you carry in. Nothing has to be reachable.

What makes it work is that a Sigstore bundle is self-contained: it holds the signing certificate, the Rekor inclusion proof and a signed timestamp, so the only thing cosign needs from the outside is the Sigstore trust root. Each release attaches one archive holding all of it:

```
agledger-<version>-offline-verification.tar.gz
agledger-<version>-offline-verification.tar.gz.sha256
agledger-<version>-offline-verification.tar.gz.sigstore.json
```

It unpacks to `offline-verification/`, holding `trusted_root.json`, the signed index and each platform manifest, the signature bundle, the CycloneDX, OpenVEX and malware-scan attestation bundles, and a `version` file naming the release it is for.

**The archive is signed, and the signature is the part to check while you still have a network.** `trusted_root.json` is the anchor every check inside the enclave hangs from, so an archive swapped in transit is an anchor swapped in transit, and the `.sha256` beside it would agree with the swap. The `cosign verify-blob` in the Procedure above is what settles that, and it is the same recipe as for the conformance corpus.

Verify the image in the enclave, against the one you just loaded or pushed:

```bash
sha256sum -c agledger-${VERSION}-offline-verification.tar.gz.sha256
tar xzf agledger-${VERSION}-offline-verification.tar.gz
./scripts/verify-release.sh \
  --version ${VERSION} \
  --image registry.internal.example.com/agledger \
  --bundle-dir ./offline-verification
```

It checks the signature and all three attestations, asserts the malware scan reports `no-detections`, and refuses by name if any of that is missing or does not hold.

That is the same check `install.sh` runs, so set `AGLEDGER_VERIFY_BUNDLE_DIR` and the install verifies too, including under `AGLEDGER_REQUIRE_VERIFY=true`:

```bash
AGLEDGER_VERIFY_BUNDLE_DIR=$PWD/offline-verification \
AGLEDGER_REQUIRE_VERIFY=true \
./scripts/install.sh --image registry.internal.example.com/agledger --version ${VERSION} --non-interactive
```

Requires **cosign 3.x** and **jq** on the enclave host. No `crane`, no registry, no Rekor.

### What it proves, and how it reaches the bytes you loaded

Two links, and both have to hold.

The signature is over the release's multi-arch **index digest**. `index.json` in the bundle is that index, verbatim, so its own sha256 is the digest the signature has to name: the file is tied to the signature by content, not by a number you typed.

Then the loaded image has to be *in* that index. `docker save` and `docker load` rebuild the manifest, and pushing to a mirror rewrites it again, so neither the index digest nor the platform manifest digest survives the round trip. The **image config digest** does, and the daemon reports it as the image ID, so the chain the check walks is index, platform manifest, config digest, `docker image inspect --format '{{.Id}}'`. An image that was rebuilt, altered, or is simply a different version has a different config digest and is refused by name.

### Mirroring so the mirror keeps the signature

The release signature and attestations are attached to the image as **OCI referrers**. `docker save`, `docker load` and `docker push` carry none of them, and neither does `cosign copy`. `oras cp -r` does, on any registry: through the referrers API where the registry implements OCI 1.1, and through the OCI referrers fallback tag where it does not.

Mirror that way, on a connected machine that can reach both, and the enclave's own registry serves the signature. Then the only file to stage out of band is `trusted_root.json`:

```bash
oras cp -r docker.io/agledger/agledger:${VERSION} registry.internal.example.com/agledger:${VERSION}
```

`verify-release.sh` and `install.sh` take that path automatically when the registry answers with the referrers; the rest of the bundle is what they fall back to when it does not.

The plain `docker save` route in the Procedure above is the one to use when the two networks are never connected at once, and the carried bundle is what verifies it.

## Carry the Postgres image too

A default install runs the bundled Postgres, and that image comes from Docker Hub whatever `--image` says. Save it alongside the release on the connected machine:

```bash
docker pull postgres:18-alpine
docker save postgres:18-alpine | gzip > postgres-18-alpine.tar.gz
```

Load it in the enclave before installing. `--with-monitoring` pulls four more Docker Hub images (OpenTelemetry Collector, Jaeger, Prometheus, Grafana); carry those the same way or leave the flag off. If an image is missing the installer says which one, before it starts anything.

An external database (`--external-db`) needs no database image to run. It still needs a PostgreSQL client matching the server's major version for `backup.sh`, which `upgrade.sh` runs first. When the host has no `pg_dump` of that major, the scripts run one from `postgres:<major>-alpine`. Carry that image, or point `PG_CLIENT_IMAGE_REPO` at your registry's copy of `postgres` (the scripts append the tag: `<major>-alpine` for the dump client and `18-alpine` for the version check), or install the matching client tools on the host.

## No registry inside the enclave

The procedure above pushes to an internal registry because the installer pulls before it runs anything. An enclave with no registry at all can install from the local image store instead: load the images and point the installer at the carried verification bundle.

```bash
docker load < agledger-${VERSION}.tar.gz        # the tag-saved bundle from "Procedure" above
docker load < postgres-18-alpine.tar.gz
tar xzf agledger-${VERSION}-offline-verification.tar.gz
AGLEDGER_VERIFY_BUNDLE_DIR=$PWD/offline-verification \
./scripts/install.sh --version ${VERSION} --non-interactive
```

Without either the bundle or `--skip-verify` the installer refuses rather than run bytes it could not check, and it says which image it would not run. `--skip-verify` still exists and still means what it says: it checks nothing. With the bundle there is no reason to reach for it.

Load the **tag-saved** bundle for this, the one from the Procedure section. A tarball produced by `docker save agledger/agledger@sha256:...` restores as a bare image ID with no repository or tag, and the installer has no name to look up; tag it yourself first.

`docker load` drops the RepoDigest, so there is no registry digest to pin. When the install verified the loaded image from a carried bundle (`AGLEDGER_VERIFY_BUNDLE_DIR`), it pins the image id the check chained to the signed index instead (`AGLEDGER_IMAGE_PIN=sha256:<config digest>`), and Compose resolves that id from the local store without asking a registry, so the bytes that were verified are the bytes that run. Without the bundle nothing was verified, no pin is written, and Compose runs `${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}` by tag.

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

The chart runs three more images, each with its own override. `postgres.bundled.image` is the bundled database and the migration Job's wait-for-database init container. `backup.image` defaults to that same PostgreSQL image, so an external database with backups on still pulls it unless you set `backup.image`. `tests.image` is the Pod `helm test` runs. To list every image the release will pull, render it with the same flags you install with (including the `--set image.*` overrides and the signing-key `--set-file`, without which the render stops) and read the `image:` lines: `helm template agledger agledger-chart-${VERSION}.tgz <your install flags> | grep 'image:' | sort -u`.

`helm-install.sh`, the guided path, works here too: `--chart` takes the local `.tgz` and `--image` takes your mirror, and it generates the signing key and answers the database questions as it does anywhere else.

```bash
./scripts/helm-install.sh \
  --chart ./agledger-chart-${VERSION}.tgz \
  --image registry.internal.example.com/agledger \
  --version ${VERSION} \
  --external-url https://agledger.internal.example.com \
  --db postgresql://user:pass@db.internal/agledger \
  --set postgres.bundled.image=registry.internal.example.com/postgres:18-alpine \
  --set backup.image=registry.internal.example.com/postgres:18-alpine \
  --set tests.image=registry.internal.example.com/curl:8.18.0
```

It says on every such run that it verified nothing, and it refuses outright under `AGLEDGER_REQUIRE_VERIFY=true`: the release signatures are OCI referrers on Docker Hub, and a chart `helm pull` wrote to a `.tgz` carries none of them. Verify the image with `verify-release.sh` as above, before or after.

## Carry the offline chain verifier

`@agledger/verify` is what reads a vault dump or an `/audit-export` document and checks the hash chain and the signatures, without the Server. It ships on npm only, so an enclave needs it carried in. Build the tree on the connected machine and move the tree, rather than a list of tarballs: npm resolves the versions there, and its `@agledger/verify-core` and `cborg` dependencies are pinned exactly, so a hand-picked `npm pack` set is one release away from not installing.

```bash
mkdir agledger-verify && cd agledger-verify
npm install --omit=dev @agledger/verify
cd .. && tar czf agledger-verify.tar.gz -C agledger-verify .
```

In the enclave, unpack and run it. Nothing is installed and nothing is fetched:

```bash
mkdir agledger-verify && tar xzf agledger-verify.tar.gz -C agledger-verify
cd agledger-verify
./node_modules/.bin/agledger-verify ./vault-dump/
```

Needs Node 24 or later on the host. `./scripts/vault-dump.sh` writes the dump it reads.

## License Activation

Enterprise license files can be delivered out of band. Place the `.pem` at the configured path (default `/etc/agledger/license.pem`) or set `AGLEDGER_LICENSE_KEY_FILE` to its location. No network access is required for validation.
