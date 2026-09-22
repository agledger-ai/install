#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger: verify a release with no network
# =============================================================================
# Runs the same check install.sh and upgrade.sh run, on its own, so an operator
# can verify before installing and an enclave can verify at all. There is one
# implementation of it: verify_release_offline in lib-compose.sh.
#
# What it needs, all carried in from the connected side:
#   - the release's offline-verification bundle, unpacked
#     (agledger-<version>-offline-verification.tar.gz, on the GitHub release)
#   - the image itself, in this host's image store or on a registry this host
#     can reach
#   - cosign 3.x and jq
#
# Usage:
#   ./scripts/verify-release.sh --version X.Y.Z --bundle-dir ./offline-verification
#   ./scripts/verify-release.sh --version X.Y.Z --image registry.internal/agledger \
#       --bundle-dir ./offline-verification
#
# Exit codes:
#   0 = verified
#   1 = verification failed: do not run these bytes
#   2 = the image is neither on a reachable registry nor in the image store
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

IMAGE="agledger/agledger"
VERSION=""
BUNDLE_DIR="${AGLEDGER_VERIFY_BUNDLE_DIR:-}"

usage() {
  cat <<'USAGE'
Usage: ./scripts/verify-release.sh --version X.Y.Z [OPTIONS]

Options:
  --version VERSION     Release to verify. Required.
  --image IMAGE         Image repository (default: agledger/agledger). Point it
                        at your mirror when the release was mirrored.
  --bundle-dir DIR      Unpacked agledger-<version>-offline-verification.tar.gz.
                        Defaults to $AGLEDGER_VERIFY_BUNDLE_DIR.
  -h, --help            Print this and exit.

The bundle directory is not needed when the mirror was made with `oras cp -r`,
which carries the release's signature to the mirror, and the trust root is the
only file to stage. Everything else drops the signature, and then the bundle is
what there is to verify against.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)    VERSION="$2"; shift 2 ;;
    --image)      IMAGE="$2"; shift 2 ;;
    --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            fatal "Unknown argument: $1 (use --help for usage)" ;;
  esac
done

[[ -n "$VERSION" ]] || fatal "--version is required: a signature is over one release's bytes, not a repository."
[[ -n "$BUNDLE_DIR" ]] || fatal "--bundle-dir is required (or set AGLEDGER_VERIFY_BUNDLE_DIR). It holds trusted_root.json at minimum."

command -v docker >/dev/null 2>&1 || fatal "docker is required: the check ends at the bytes the daemon holds."

# Checked here rather than left to verify_image, which looks for the image
# first: a mistyped --bundle-dir would otherwise be reported as an image that
# never arrived, and send the operator after the wrong thing.
[[ -d "$BUNDLE_DIR" ]] || fatal "--bundle-dir '${BUNDLE_DIR}' is not a directory. Unpack agledger-${VERSION}-offline-verification.tar.gz and point it there."
[[ -f "${BUNDLE_DIR}/trusted_root.json" ]] || fatal "'${BUNDLE_DIR}' holds no trusted_root.json, so it is not an unpacked offline-verification bundle."

export AGLEDGER_VERIFY_BUNDLE_DIR="$BUNDLE_DIR"

STATUS=0
verify_image "$IMAGE" "$VERSION" || STATUS=$?
case $STATUS in
  0)
    info "${IMAGE}:${VERSION} is a genuine AGLedger release."
    ;;
  2)
    error "Nothing was verified: ${IMAGE}:${VERSION} never arrived."
    ;;
  *)
    error "${IMAGE}:${VERSION} did NOT verify. Do not run it."
    ;;
esac
exit $STATUS
