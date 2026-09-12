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
# dev-only verify script — it runs the checker that already ships inside the
# AGLedger image (dist/scripts/verify-vault.js), so no source checkout, Node.js,
# or pnpm is required on the host.
#
# The vault holds two kinds of chain and both are checked: one per record, and
# one per org for schema registrations (reported as `schema:<orgId>`). The
# summary says how many of each were covered. A chain holding no entries is
# reported as EMPTY, not as a pass: nothing about it was proven. A record whose
# entries were all deleted is reported that way too, rather than dropping out of
# the count: the check enumerates the record rows, not just the surviving vault
# entries.
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
#   ./scripts/vault-verify.sh                      # check every chain
#   ./scripts/vault-verify.sh --chain-key <key>    # check one chain, named the
#                                                  # way the report prints it:
#                                                  # a record uuid, or
#                                                  # schema:<orgId> /
#                                                  # schema:__platform__
#   ./scripts/vault-verify.sh --record-id <uuid>   # check one record's chain
#   ./scripts/vault-verify.sh --since <date>       # chains written since a date
#   ./scripts/vault-verify.sh --json               # machine-readable report
#
# After a FAIL line, re-run with --chain-key and the key that line printed.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

usage() {
  sed -n '4,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
