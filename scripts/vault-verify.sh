#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Vault Integrity Check
# =============================================================================
# Runs the connected hash / link / position integrity check over the live audit
# chain: every entry's chain_position is sequential, payload_hash matches the
# SHA-256 of its COSE_Sign1 envelope, the genesis entry has no previous_hash,
# and each previous_hash links to the prior entry. Exits 0 if intact, 1 if any
# break is found. This is the customer-runnable equivalent of the monorepo dev
# script `pnpm vault:verify` — it runs the checker that already ships inside the
# AGLedger image (dist/scripts/verify-vault.js), so no source checkout, Node.js,
# or pnpm is required on the host.
#
# This is the fast in-database integrity check (no signature verification) — the
# right post-restore "is my chain internally consistent?" proof. The
# signature-checking, database-independent proof an external auditor runs is
# `./scripts/vault-dump.sh` plus the offline verifier; see the "Offline
# cryptographic verification" section of GET /llms-full.txt.
#
# Requires the AGLedger stack (or at least its database) to be reachable on the
# compose network — run this against a live install.
#
# Usage:
#   ./scripts/vault-verify.sh                      # check every record's chain
#   ./scripts/vault-verify.sh --record-id <uuid>   # check one record
#   ./scripts/vault-verify.sh --since <date>       # check records since a date
#   ./scripts/vault-verify.sh --json               # machine-readable report
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

# One-off container reusing the agledger-api service definition (carries
# DATABASE_URL/.env/CA config). --entrypoint forces node and drops the image's
# --permission CMD. No volume mount or --user override is needed: the checker
# only reads the database and prints its report to stdout. exec so the
# checker's 0/1 exit status propagates to the caller.
exec "${COMPOSE[@]}" run --rm --no-deps \
  --entrypoint /nodejs/bin/node \
  agledger-api dist/scripts/verify-vault.js "$@"
