#!/usr/bin/env bash
# AGLedger Helm Quick-Start — generates secrets and installs in one command.
#
# Usage:
#   curl -fsSL https://agledger.ai/helm-install.sh | bash
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --db postgresql://user:pass@host/db
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --bundled
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --values my-values.yaml
#
# External-database TLS:
#   The image bundles the AWS RDS / Aurora root CA at /etc/ssl/certs/rds-global-bundle.pem.
#   It is auto-applied when an external DB is chosen interactively.
#     --ca-cert <path>   override the cert path (must exist inside the container)
#     --no-ca-cert       skip the cert (only safe for DBs that don't require TLS)
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
CA_CERT=""
# Bundled in the agledger/agledger image at build time. Covers AWS RDS / Aurora.
DEFAULT_RDS_CA="/etc/ssl/certs/rds-global-bundle.pem"

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
    --marketplace)  EXTRA_ARGS="$EXTRA_ARGS --set marketplace.productId=$2"; shift 2 ;;
    --ca-cert)      CA_CERT="$2"; shift 2 ;;
    --no-ca-cert)   CA_CERT="none"; shift ;;
    --skip-verify)  export AGLEDGER_SKIP_VERIFY=true; shift ;;
    *)              EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
  esac
done

# Keyless signature verification (cross-repo #667). The release pipeline signs
# the chart + image via GitHub OIDC -> Fulcio -> public Rekor. This bootstrap is
# advertised as curl|bash, so it MUST verify before it installs/runs anything.
AGLEDGER_SIGNER_IDENTITY_REGEXP='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
AGLEDGER_SIGNER_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# verify_ref <oci-ref> <human-label> — fail-closed when cosign is present and
# verification fails; warn + proceed when cosign is absent (OOTB-first), unless
# AGLEDGER_REQUIRE_VERIFY=true.
verify_ref() {
  local ref="$1" label="$2"
  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    info "AGLEDGER_SKIP_VERIFY=true — skipping ${label} verification (dev/local ONLY)."
    return 0
  fi
  if ! command -v cosign >/dev/null 2>&1; then
    [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]] \
      && fatal "cosign not installed and AGLEDGER_REQUIRE_VERIFY=true. Install cosign 3.x: https://docs.sigstore.dev/system_config/installation/"
    info "cosign not installed — cannot verify ${label}. Install cosign 3.x for supply-chain verification. Proceeding UNVERIFIED."
    return 0
  fi
  if cosign verify \
       --certificate-identity-regexp "$AGLEDGER_SIGNER_IDENTITY_REGEXP" \
       --certificate-oidc-issuer "$AGLEDGER_SIGNER_OIDC_ISSUER" \
       "$ref" >/dev/null 2>&1; then
    info "Verified ${label} signature (keyless, public Rekor): ${ref}"
    return 0
  fi
  fatal "Signature verification FAILED for ${label} (${ref}). Refusing to proceed. Override for dev ONLY: --skip-verify"
}

# Resolve a public Docker Hub tag -> immutable digest (sha256:...), or empty.
# Lets us verify + run the exact bytes by digest instead of a mutable tag.
resolve_dockerhub_digest() {
  local repo="$1" tag="$2" token
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  token=$(curl -fsSL --max-time 10 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null)
  [[ -n "$token" ]] || return 0
  curl -fsSL --max-time 10 -o /dev/null -D - \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r' || true
}

echo ""
echo "  AGLedger Helm Quick-Start"
echo "  ========================"
echo ""

# Check prerequisites
command -v helm >/dev/null 2>&1 || fatal "helm is required. Install: https://helm.sh/docs/intro/install/"
command -v kubectl >/dev/null 2>&1 || fatal "kubectl is required."
kubectl cluster-info >/dev/null 2>&1 || fatal "No Kubernetes cluster available. Check kubectl config."

# Resolve a concrete version so the chart + image can be pinned AND verified.
# cosign needs a concrete tag, not a floating "latest".
if [[ -z "$VERSION" ]] && [[ "${AGLEDGER_SKIP_VERIFY:-false}" != "true" ]]; then
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # `|| true`: under `set -euo pipefail` a no-match `grep` would otherwise abort
    # the whole script instead of falling through to the graceful message below.
    VERSION=$(curl -fsSL --max-time 10 \
      "https://hub.docker.com/v2/repositories/agledger/agledger-chart/tags?page_size=100" 2>/dev/null \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)
    [[ -n "$VERSION" ]] && info "Resolved latest chart version: $VERSION"
  fi
  [[ -z "$VERSION" ]] && info "Could not resolve a concrete version to verify — pass --version X.Y.Z to enable verification."
fi

# Verify the chart (#667-C2) and the image before installing / running them.
# Resolve the image to a digest and verify THAT (not the mutable tag), so the
# keygen pod below runs exactly the bytes we verified — no verify-then-repoint gap.
IMG_REF="agledger/agledger${VERSION:+:$VERSION}"
if [[ -n "$VERSION" ]]; then
  verify_ref "registry-1.docker.io/agledger/agledger-chart:$VERSION" "Helm chart"
  IMG_DIGEST=$(resolve_dockerhub_digest agledger/agledger "$VERSION")
  if [[ "${IMG_DIGEST:-}" == sha256:* ]]; then
    verify_ref "registry-1.docker.io/agledger/agledger@$IMG_DIGEST" "container image"
    IMG_REF="agledger/agledger@$IMG_DIGEST"
  else
    verify_ref "registry-1.docker.io/agledger/agledger:$VERSION" "container image"
  fi
elif [[ "${AGLEDGER_SKIP_VERIFY:-false}" != "true" ]] && [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
  fatal "AGLEDGER_REQUIRE_VERIFY=true but no concrete version to verify. Pass --version X.Y.Z."
fi

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
       [[ -n "$DB_URL" ]] || fatal "DATABASE_URL is required for external database"
       if [[ -z "$CA_CERT" ]]; then
         echo ""
         echo "  Database TLS root CA?"
         echo "    Press Enter to use the bundled AWS RDS / Aurora cert (${DEFAULT_RDS_CA})"
         echo "    Type a path inside the container for a custom CA"
         echo "    Type 'none' to skip (most managed Postgres providers require a CA)"
         read -rp "  CA cert [${DEFAULT_RDS_CA}]: " ca_choice
         CA_CERT="${ca_choice:-$DEFAULT_RDS_CA}"
       fi
       ;;
    *) fatal "Invalid option" ;;
  esac
fi

# Generate vault signing key using the AGLedger container
info "Generating Ed25519 vault signing key..."
VAULT_KEY=$(kubectl run agledger-keygen --rm -it --restart=Never \
  --image="$IMG_REF" \
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
  if [[ -n "$CA_CERT" && "$CA_CERT" != "none" ]]; then
    HELM_CMD="$HELM_CMD --set config.nodeExtraCaCerts=$CA_CERT"
    info "Using TLS CA cert: $CA_CERT"
  fi
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
echo "       curl -H 'Authorization: Bearer <platform-key>' http://localhost:3001/v1/admin/license"
echo ""
if [[ -n "$VAULT_KEY" ]]; then
  echo "    Vault signing key (save this for backup/rotation):"
  echo "       $VAULT_KEY"
  echo ""
fi
echo "    Documentation: https://agledger.ai/docs"
echo "    Upgrade to Enterprise: https://agledger.ai/pricing"
echo ""
