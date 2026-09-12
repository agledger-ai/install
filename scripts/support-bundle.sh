#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Support Bundle
# =============================================================================
# Creates a diagnostic tarball with logs, config, schema, and stats.
# All secrets are automatically redacted.
# Works with both bundled PostgreSQL and external databases.
#
# Usage: ./scripts/support-bundle.sh
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

# Row counts and sizes per table, shared by the bundled-PG and external-psql
# branches below so the two cannot drift apart.
#
# This covers every schema in the database, not only AGLedger's tables. That is
# the point on a bundled PostgreSQL, which holds nothing else. On an external
# database the operator is told what that means before it is collected (see the
# notice in the external branch below); GET /v1/admin/support-bundle, which
# customers can expose more widely, is allowlisted to our own tables instead.
#
# `pg_stat_user_tables` reports a partitioned parent's own heap, and a
# partitioned table (relkind 'p') has no heap of its own, so audit_vault,
# events, system_audit_log, webhook_deliveries
# and pgboss.job all read as 0 rows and 0 bytes no matter how full they are.
# Roll each partition tree up into its parent and drop the leaf rows, so a
# reader is not summing partitions by hand and the counts agree with
# GET /v1/admin/support-bundle for the tables that endpoint covers.
# Sizes come from the leaves for the same reason: a partitioned index
# (relkind 'I') stores nothing either, and `pg_total_relation_size` on a leaf
# already counts that leaf's indexes and TOAST.
TABLE_STATS_SQL="
SELECT s.schemaname,
       s.relname,
       COALESCE((SELECT SUM(st.n_live_tup) FROM pg_partition_tree(s.relid) pt
                   JOIN pg_stat_all_tables st ON st.relid = pt.relid
                  WHERE pt.isleaf), s.n_live_tup) AS n_live_tup,
       COALESCE((SELECT SUM(pg_total_relation_size(pt.relid)) FROM pg_partition_tree(s.relid) pt
                  WHERE pt.isleaf), pg_total_relation_size(s.relid)) AS total_bytes,
       pg_size_pretty(COALESCE((SELECT SUM(pg_total_relation_size(pt.relid)) FROM pg_partition_tree(s.relid) pt
                  WHERE pt.isleaf), pg_total_relation_size(s.relid))) AS total_size
  FROM pg_stat_user_tables s
  JOIN pg_class c ON c.oid = s.relid
 WHERE NOT c.relispartition
 ORDER BY n_live_tup DESC;"

if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  collect "schema dump (no data)" "db-schema.sql" \
    "${COMPOSE[@]}" exec -T postgres pg_dump -U "${POSTGRES_USER}" --schema-only "${POSTGRES_DB}"

  collect "table row counts" "db-table-stats.txt" \
    "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
    "${TABLE_STATS_SQL}"

  collect "migration state" "db-migrations.txt" \
    "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
    "SELECT * FROM _migrations ORDER BY id;"
else
  if command -v psql &>/dev/null; then
    # An external database can be shared with other applications, and both
    # collections below read all of it. Say so in the tarball as well as on
    # stdout: the file is what support and the operator read later.
    {
      echo "Scope of the database files in this bundle"
      echo ""
      echo "This install uses an EXTERNAL database, so db-schema.sql and"
      echo "db-table-stats.txt cover every schema in it, not just AGLedger's"
      echo "tables. If other applications share this database, their table and"
      echo "column definitions are in db-schema.sql and their row counts and"
      echo "sizes are in db-table-stats.txt."
      echo ""
      echo "Review both files before sending this tarball, and delete what does"
      echo "not belong to AGLedger. Nothing here contains row data or secrets."
    } > "${BUNDLE_DIR}/db-collection-scope.txt"
    log "External database: db-schema.sql and db-table-stats.txt cover EVERY schema in it, including relations AGLedger did not create. Review both before sending the tarball (see db-collection-scope.txt)."

    collect "schema dump (no data)" "db-schema.sql" \
      pg_dump "${DATABASE_URL}" --schema-only

    collect "table row counts" "db-table-stats.txt" \
      psql "${DATABASE_URL}" -c \
      "${TABLE_STATS_SQL}"

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

# The API's published host port is configurable (AGLEDGER_HOST_PORT), so read
# what this install actually serves rather than assuming the stock 3001.
API_HOST_PORT="$(resolve_host_port AGLEDGER_HOST_PORT 3001)"

collect "GET /health" "health.json" \
  curl -sf --max-time 5 "http://localhost:${API_HOST_PORT}/health"

collect "GET /v1/conformance" "conformance.json" \
  curl -sf --max-time 5 "http://localhost:${API_HOST_PORT}/v1/conformance"

collect "GET /status" "status.json" \
  curl -sf --max-time 5 "http://localhost:${API_HOST_PORT}/status"

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
