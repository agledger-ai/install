#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Vault Dump
# =============================================================================
# Produces the NDJSON vault dump that the offline cryptographic verifier
# consumes: one file per audit table (audit_vault, vault_checkpoints,
# vault_signing_keys, org_admin_reads, org_admin_reads_checkpoints), each row
# carrying its canonical COSE_Sign1 bytes. This is the customer-runnable
# equivalent of the monorepo dev script `pnpm vault:dump` — it runs the dump
# tool that already ships inside the AGLedger image (dist/scripts/dump-vault.js),
# so no source checkout, Node.js, or pnpm is required on the host.
#
# Works with both bundled PostgreSQL and external databases (Aurora, RDS, etc.):
# the dump runs inside a one-off container that reuses the agledger-api service
# definition, so it inherits the same DATABASE_URL, .env, and CA-bundle config
# the running Server uses.
#
# Requires the AGLedger stack (or at least its database) to be reachable on the
# compose network — run this against a live install.
#
# Usage:
#   ./scripts/vault-dump.sh                       # dump all orgs to ./vault-dump-<ts>
#   ./scripts/vault-dump.sh ./my-dump             # dump all orgs to ./my-dump
#   ./scripts/vault-dump.sh ./my-dump --org <id>  # scope to one org
#
# Verify the resulting dump offline — see the "Offline cryptographic
# verification" section of GET /llms-full.txt for the supported paths.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

usage() {
  sed -n '4,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

OUT_DIR=""
ORG_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --org) ORG_ID="${2:?--org requires an org id}"; shift 2 ;;
    --org=*) ORG_ID="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "Unknown option: $1" ;;
    *)
      if [[ -z "$OUT_DIR" ]]; then OUT_DIR="$1"; else die "Unexpected argument: $1"; fi
      shift
      ;;
  esac
done

OUT_DIR="${OUT_DIR:-${REPO_ROOT}/vault-dump-$(date -u '+%Y-%m-%d-%H%M%S')}"

load_env
detect_db_mode
build_compose_cmd

mkdir -p "$OUT_DIR"
ABS_OUT="$(cd "$OUT_DIR" && pwd)"

log "Dumping vault to: ${ABS_OUT}"
[[ -n "$ORG_ID" ]] && log "Scoped to org: ${ORG_ID}"

# argv passed to node inside the container. The dump writes to /dump, which is
# the bind-mounted output directory.
DUMP_ARGS=(dist/scripts/dump-vault.js /dump)
[[ -n "$ORG_ID" ]] && DUMP_ARGS+=(--org "$ORG_ID")

# One-off container reusing the agledger-api service definition:
#   --no-deps     don't (re)start postgres/migrate — run against the live stack
#   --user        write output as the invoking host user, not container nonroot,
#                 so the customer owns the dump files
#   -v            bind-mount the host output dir to /dump
#   --entrypoint  force /nodejs/bin/node and drop the image's --permission CMD
#                 (the dump must write files; the hardened CMD denies fs writes)
"${COMPOSE[@]}" run --rm --no-deps \
  --user "$(id -u):$(id -g)" \
  -v "${ABS_OUT}:/dump" \
  --entrypoint /nodejs/bin/node \
  agledger-api "${DUMP_ARGS[@]}"

# --- Summary ---

echo ""
log "========================================="
log "Vault dump complete"
log "  Directory: ${ABS_OUT}"
for f in "${ABS_OUT}"/*.ndjson; do
  [[ -f "$f" ]] || continue
  log "  $(basename "$f"): $(wc -l < "$f") rows"
done
log ""
log "Verify this dump offline. The supported verification paths (stock RFC 9052"
log "libraries against the per-row cose_sign1 bytes, and the @agledger/cli"
log "'verify' subcommand which consumes this dump format) are documented under"
log "'Offline cryptographic verification' in GET <your-server>/llms-full.txt."
log "========================================="
