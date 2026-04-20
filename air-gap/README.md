# Air-Gapped Installation

`install.sh --image` points the installer at an internal registry instead of Docker Hub. That is the supported air-gap path — pull the image on an internet-connected machine, transfer it, push to your registry, then install.

## Procedure

On a machine with internet access:

```bash
VERSION=0.19.13
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

The public cosign key is at `cosign.pub` in this repo. Verify after loading:

```bash
cosign verify --key cosign.pub agledger/agledger:${VERSION}
```
