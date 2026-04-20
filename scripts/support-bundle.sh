#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Support Bundle
# =============================================================================
# Creates a diagnostic tarball with logs, config, schema, and stats.
# All secrets are automatically redacted.
# Works with both bundled PostgreSQL and external databases.
#
# Usage: ./deploy/scripts/support-bundle.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

TIMESTAMP="$(date -u '+%Y-%m-%d-%H%M%S')"
BUNDLE_DIR="$(mktemp -d)/support-bundle-${TIMESTAMP}"
mkdir -p "${BUNDLE_DIR}"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }

load_env
detect_db_mode
build_compose_cmd

# Helper: run a command and save output, tolerating failures
collect() {
  local label="$1"
  local outfile="$2"
  shift 2
  log "Collecting: ${label}..."
  if "$@" > "${BUNDLE_DIR}/${outfile}" 2>&1; then
    return 0
  else
    echo "[COLLECTION FAILED: exit code $?]" >> "${BUNDLE_DIR}/${outfile}"
    return 0
  fi
}

# --- Redacted .env ---

log "Collecting: redacted .env..."
if [[ -f "${COMPOSE_DIR}/.env" ]]; then
  sed -E \
    -e 's/(PASSWORD|PASS|SECRET|KEY|TOKEN|SIGNING)=.*/\1=[REDACTED]/' \
    -e 's/(DATABASE_URL[^=]*=.*:)([^@]*)(@.*)/\1[REDACTED]\3/' \
    "${COMPOSE_DIR}/.env" > "${BUNDLE_DIR}/env-redacted.txt"
else
  echo "[.env file not found]" > "${BUNDLE_DIR}/env-redacted.txt"
fi

# --- Docker Compose state ---

collect "docker compose ps" "compose-ps.txt" \
  "${COMPOSE[@]}" ps

collect "docker compose logs (last 1000 lines)" "compose-logs.txt" \
  "${COMPOSE[@]}" logs --tail 1000 --no-color

# --- PostgreSQL diagnostics ---

if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  collect "schema dump (no data)" "db-schema.sql" \
    "${COMPOSE[@]}" exec -T postgres pg_dump -U "${POSTGRES_USER}" --schema-only "${POSTGRES_DB}"

  collect "table row counts" "db-table-stats.txt" \
    "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
    "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"

  collect "migration state" "db-migrations.txt" \
    "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
    "SELECT * FROM _migrations ORDER BY id;"
else
  if command -v psql &>/dev/null; then
    collect "schema dump (no data)" "db-schema.sql" \
      pg_dump "${DATABASE_URL}" --schema-only

    collect "table row counts" "db-table-stats.txt" \
      psql "${DATABASE_URL}" -c \
      "SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"

    collect "migration state" "db-migrations.txt" \
      psql "${DATABASE_URL}" -c \
      "SELECT * FROM _migrations ORDER BY id;"
  else
    echo "[External database — psql not installed, DB diagnostics skipped]" > "${BUNDLE_DIR}/db-schema.sql"
    log "psql not found — skipping external DB diagnostics. Install PostgreSQL client tools for full bundles."
  fi
fi

# --- System info ---

collect "docker version" "docker-version.txt" \
  docker version

collect "system info (uname)" "system-uname.txt" \
  uname -a

collect "memory (free -h)" "system-memory.txt" \
  free -h

collect "disk (df -h)" "system-disk.txt" \
  df -h

# --- Health endpoints ---

collect "GET /health" "health.json" \
  curl -sf --max-time 5 http://localhost:3001/health

collect "GET /conformance" "conformance.json" \
  curl -sf --max-time 5 http://localhost:3001/conformance

collect "GET /status" "status.json" \
  curl -sf --max-time 5 http://localhost:3001/status

# --- AGLedger version ---

log "Collecting: AGLedger version..."
{
  echo "AGLEDGER_VERSION=${AGLEDGER_VERSION:-unknown}"
  echo "Database: $(if [[ "${USES_BUNDLED_PG}" == "true" ]]; then echo "bundled"; else echo "external"; fi)"
  echo "Image: $("${COMPOSE[@]}" config --images 2>/dev/null | grep agledger | head -1 || echo 'unknown')"
} > "${BUNDLE_DIR}/agledger-version.txt"

# --- Create tarball ---

TARBALL="${REPO_ROOT}/support-bundle-${TIMESTAMP}.tar.gz"
log "Creating tarball: ${TARBALL}"
tar -czf "${TARBALL}" -C "$(dirname "${BUNDLE_DIR}")" "$(basename "${BUNDLE_DIR}")"

# Cleanup temp
rm -rf "$(dirname "${BUNDLE_DIR}")"

TARBALL_SIZE=$(du -sh "${TARBALL}" | cut -f1)

echo ""
log "========================================="
log "Support bundle created"
log "  File: ${TARBALL}"
log "  Size: ${TARBALL_SIZE}"
log ""
log "  Send this file to support@agledger.ai"
log "========================================="
