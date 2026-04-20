#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Restore Script
# =============================================================================
# Restores PostgreSQL data from a backup tarball.
# Works with both bundled PostgreSQL and external databases (Aurora, RDS, etc.).
#
# Usage: ./deploy/scripts/restore.sh backup/backup-2026-03-14-120000.tar.gz
#        ./deploy/scripts/restore.sh --non-interactive backup/backup-2026-03-14-120000.tar.gz
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

# Parse arguments
TARBALL=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -*) die "Unknown option: $1" ;;
    *) TARBALL="$1"; shift ;;
  esac
done

[[ -n "${TARBALL}" ]] || die "Usage: $0 [--non-interactive] <backup-tarball>"
[[ -f "${TARBALL}" ]] || die "Backup file not found: ${TARBALL}"

load_env
detect_db_mode
build_compose_cmd

# --- Confirmation ---

if [[ "${NON_INTERACTIVE}" != "true" ]]; then
  echo ""
  echo "  WARNING: This will REPLACE all data in the database."
  echo "  Backup file: ${TARBALL}"
  if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
    echo "  Database: External ($(echo "${DATABASE_URL}" | sed -E 's|://[^@]*@|://***@|' | cut -d'?' -f1))"
  else
    echo "  Database: Bundled PostgreSQL"
  fi
  echo ""
  read -rp "  Continue? (y/N) " confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    log "Restore cancelled."
    exit 0
  fi
fi

# --- Extract tarball ---

RESTORE_TMP="$(mktemp -d)"
trap 'rm -rf "${RESTORE_TMP}"' EXIT

log "Extracting backup to ${RESTORE_TMP}..."
tar -xzf "${TARBALL}" -C "${RESTORE_TMP}"

# Find the extracted directory (timestamp-named)
RESTORE_DIR=$(find "${RESTORE_TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -d "${RESTORE_DIR}" ]] || die "No directory found in backup tarball."
[[ -f "${RESTORE_DIR}/db.dump" ]] || die "db.dump not found in backup."

# --- Stop application services ---

log "Stopping application services..."
"${COMPOSE[@]}" stop agledger-api agledger-worker 2>/dev/null || true
"${COMPOSE[@]}" rm -f agledger-migrate 2>/dev/null || true

# --- Restore PostgreSQL ---

log "Restoring PostgreSQL database..."

if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  # External database — use pg client tools directly with DATABASE_URL
  if ! command -v psql &>/dev/null || ! command -v pg_restore &>/dev/null; then
    die "psql and pg_restore are required for external database restore. Install PostgreSQL client tools."
  fi

  # Use DATABASE_URL_MIGRATE if available (owner role for DDL), else DATABASE_URL
  RESTORE_URL="${DATABASE_URL_MIGRATE:-${DATABASE_URL}}"

  # Connect to the target database to terminate active connections
  psql "${RESTORE_URL}" -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true

  # Drop and recreate via psql connected to the 'postgres' maintenance database
  psql "${RESTORE_URL}" -d postgres -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\";" 2>/dev/null || true
  psql "${RESTORE_URL}" -d postgres -c "CREATE DATABASE \"${POSTGRES_DB}\";" \
    || die "Failed to recreate database. Ensure the DATABASE_URL user has CREATEDB privilege."

  pg_restore -d "${RESTORE_URL}" --no-owner --no-acl \
    < "${RESTORE_DIR}/db.dump"
else
  # Bundled postgres — exec into the container
  log "Ensuring postgres is running..."
  "${COMPOSE[@]}" up -d postgres

  WAIT=0
  while [[ ${WAIT} -lt 30 ]]; do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER}" &>/dev/null; then
      break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
  done
  [[ ${WAIT} -lt 30 ]] || die "PostgreSQL did not become ready in 30 seconds."

  "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true

  "${COMPOSE[@]}" exec -T postgres dropdb -U "${POSTGRES_USER}" --if-exists "${POSTGRES_DB}"
  "${COMPOSE[@]}" exec -T postgres createdb -U "${POSTGRES_USER}" "${POSTGRES_DB}"

  "${COMPOSE[@]}" exec -T postgres pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --no-acl \
    < "${RESTORE_DIR}/db.dump"
fi

log "PostgreSQL restore complete."

# --- Restart all services ---

log "Restarting all services..."
"${COMPOSE[@]}" up -d --wait

echo ""
log "========================================="
log "Restore complete."
log "========================================="
