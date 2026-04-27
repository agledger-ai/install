#!/usr/bin/env bash
# AGLedger Helm Quick-Start — generates secrets and installs in one command.
#
# Usage:
#   curl -fsSL https://agledger.ai/helm-install.sh | bash
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --db postgresql://user:pass@host/db
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --bundled
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --values my-values.yaml
#
set -euo pipefail

CHART="oci://registry-1.docker.io/agledger/agledger-chart"
RELEASE="agledger"
NAMESPACE="default"
DB_URL=""
BUNDLED=false
EXTRA_VALUES=""
EXTRA_ARGS=""
VERSION=""

info()  { echo "  [*] $*"; }
fatal() { echo "  [!] $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    --db)           DB_URL="$2"; shift 2 ;;
    --bundled)      BUNDLED=true; shift ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --release)      RELEASE="$2"; shift 2 ;;
    --values)       EXTRA_VALUES="$2"; shift 2 ;;
    --version)      VERSION="$2"; shift 2 ;;
    --marketplace)  EXTRA_ARGS="$EXTRA_ARGS --set marketplace.productCode=$2"; shift 2 ;;
    *)              EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
  esac
done

echo ""
echo "  AGLedger Helm Quick-Start"
echo "  ========================"
echo ""

# Check prerequisites
command -v helm >/dev/null 2>&1 || fatal "helm is required. Install: https://helm.sh/docs/intro/install/"
command -v kubectl >/dev/null 2>&1 || fatal "kubectl is required."
kubectl cluster-info >/dev/null 2>&1 || fatal "No Kubernetes cluster available. Check kubectl config."

# Determine database mode
if [[ -n "$DB_URL" ]]; then
  info "Using external database"
elif [[ "$BUNDLED" == "true" ]]; then
  info "Using bundled PostgreSQL (dev/test only)"
else
  echo ""
  echo "  Choose a database option:"
  echo "    1) Bundled PostgreSQL (free, dev/test)"
  echo "    2) External database (Aurora, RDS, Cloud SQL)"
  echo ""
  read -rp "  Option [1]: " db_choice
  case "${db_choice:-1}" in
    1) BUNDLED=true; info "Using bundled PostgreSQL" ;;
    2) read -rp "  DATABASE_URL: " DB_URL
       [[ -n "$DB_URL" ]] || fatal "DATABASE_URL is required for external database" ;;
    *) fatal "Invalid option" ;;
  esac
fi

# Generate vault signing key using the AGLedger container
info "Generating Ed25519 vault signing key..."
VAULT_KEY=$(kubectl run agledger-keygen --rm -it --restart=Never \
  --image=agledger/agledger${VERSION:+:$VERSION} \
  --command -- /nodejs/bin/node dist/scripts/generate-signing-key.js 2>/dev/null \
  | grep -oP '(?<=VAULT_SIGNING_KEY=)\S+' | head -1 || true)

if [[ -z "$VAULT_KEY" ]]; then
  # Fallback: generate locally with openssl if available
  if command -v openssl >/dev/null 2>&1; then
    info "Generating key locally with openssl..."
    VAULT_KEY=$(openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | base64 -w0 2>/dev/null || base64 2>/dev/null)
  fi
fi

[[ -n "$VAULT_KEY" ]] || fatal "Could not generate vault signing key. Generate manually and pass via --set secrets.vaultSigningKey=..."

info "Vault signing key generated"

# Build helm install command
HELM_CMD="helm install $RELEASE $CHART"
HELM_CMD="$HELM_CMD --namespace $NAMESPACE --create-namespace"
HELM_CMD="$HELM_CMD --set secrets.vaultSigningKey=$VAULT_KEY"
[[ -n "$VERSION" ]] && HELM_CMD="$HELM_CMD --version $VERSION"

if [[ "$BUNDLED" == "true" ]]; then
  HELM_CMD="$HELM_CMD --set postgres.bundled.enabled=true"
elif [[ -n "$DB_URL" ]]; then
  HELM_CMD="$HELM_CMD --set database.externalUrl=$DB_URL"
fi

[[ -n "$EXTRA_VALUES" ]] && HELM_CMD="$HELM_CMD -f $EXTRA_VALUES"
HELM_CMD="$HELM_CMD $EXTRA_ARGS"

info "Installing AGLedger..."
echo ""
eval "$HELM_CMD"

echo ""
info "AGLedger installed. Waiting for pods..."

# Don't swallow the rollout status — a crashlooping image (F-447 class) would
# otherwise pass through silently and the script prints "Next steps:" as if
# the install succeeded. Surface the real exit so the customer sees the bad
# install before they try to use it.
if ! kubectl rollout status deployment/"$RELEASE"-agledger-api --namespace "$NAMESPACE" --timeout=120s; then
  fatal "Pod did not become ready within 120s. Check: kubectl logs deploy/$RELEASE-agledger-api -n $NAMESPACE --previous"
fi

echo ""
echo "  Next steps:"
echo "    1. Create platform API key:"
echo "       kubectl exec deploy/$RELEASE-agledger-api -n $NAMESPACE -- /nodejs/bin/node dist/scripts/init.js --non-interactive"
echo ""
echo "    2. Port-forward to access API:"
echo "       kubectl port-forward svc/$RELEASE-agledger -n $NAMESPACE 3001:80"
echo "       curl http://localhost:3001/health"
echo ""
echo "    3. View license status:"
echo "       curl -H 'Authorization: Bearer <platform-key>' http://localhost:3001/admin/license"
echo ""
if [[ -n "$VAULT_KEY" ]]; then
  echo "    Vault signing key (save this for backup/rotation):"
  echo "       $VAULT_KEY"
  echo ""
fi
echo "    Documentation: https://agledger.ai/docs"
echo "    Upgrade to Enterprise: https://agledger.ai/pricing"
echo ""
