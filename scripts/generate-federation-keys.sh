#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Generate Federation Keys
# =============================================================================
# Generates the keypair a Server needs to federate with peers and prints it in
# .env-ready form:
#
#   AGLEDGER_FEDERATION_SIGNING_KEY=<base64>      Ed25519 — signs outbound federation messages
#   AGLEDGER_FEDERATION_ENCRYPTION_KEY=<base64>   X25519  — encrypted-record channel
#
# Each key's public half + fingerprint are printed as comments — hand the public
# halves to peer operators out of band; they paste yours as `signingPublicKey`
# on their POST /federation/v1/peer handshake. There is no hub or gateway.
#
# Runs the generator inside the AGLedger image (--stdout mode), so no source
# checkout, Node.js, or pnpm is required on the host, and nothing is written to
# disk. The private keys go to stdout (a warning goes to stderr) — capture them
# straight into a secret store or your .env:
#
#   ./scripts/generate-federation-keys.sh >> compose/.env
#
# Then apply: docker compose up -d --force-recreate
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

usage() {
  sed -n '4,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
  esac
done

load_env
detect_db_mode
build_compose_cmd

# One-off container reusing the agledger-api service definition (carries the
# resolved image version). --no-deps so postgres is not started; --entrypoint
# forces node and drops the image's hardened --permission CMD. --stdout prints
# the keys to stdout and writes nothing to disk, so no volume mount is needed.
# exec so the generator's exit status propagates.
exec "${COMPOSE[@]}" run --rm --no-deps \
  --entrypoint /nodejs/bin/node \
  agledger-api dist/scripts/generate-federation-keys.js --stdout
