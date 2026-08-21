#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Backup Script
# =============================================================================
# Creates a timestamped backup of PostgreSQL (custom format).
# Works with both bundled PostgreSQL and external databases (Aurora, RDS, etc.).
#
# Usage:
#   ./scripts/backup.sh                   # Keep last 7 backups (default)
#   ./scripts/backup.sh --keep 14         # Keep last 14 backups
#   BACKUP_DIR=/mnt/backups ./scripts/backup.sh  # Custom backup root
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

KEEP=${KEEP:-7}
BACKUP_ROOT="${BACKUP_DIR:-${REPO_ROOT}/backup}"
TIMESTAMP="$(date -u '+%Y-%m-%d-%H%M%S')"
BACKUP_PATH="${BACKUP_ROOT}/${TIMESTAMP}"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep) KEEP="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

load_env
detect_db_mode
build_compose_cmd

mkdir -p "${BACKUP_PATH}"
log "Backup directory: ${BACKUP_PATH}"

# --- PostgreSQL backup ---

log "Backing up PostgreSQL..."

if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  log "Using external DATABASE_URL for pg_dump."
  # Credentials move into the environment, never argv, and the client version
  # is reconciled with the server's before the dump runs.
  pg_env_from_url "${DATABASE_URL}" || die "DATABASE_URL is not a postgres:// URL."
  pg_client_run pg_dump -Fc > "${BACKUP_PATH}/db.dump"
else
  log "Using compose postgres service."
  "${COMPOSE[@]}" exec -T postgres pg_dump -U "${POSTGRES_USER}" -Fc "${POSTGRES_DB}" > "${BACKUP_PATH}/db.dump"
fi

# The dump is checked before anything reports success on it. A backup is only
# worth what a restore can read, and both ways this file has been unreadable
# are silent at the point it is written: bytes ahead of the archive, or no
# archive at all. Discovering either at restore time means discovering it after
# restore.sh has already stopped the stack and dropped the database.
if ! pg_dump_magic_ok "${BACKUP_PATH}/db.dump"; then
  PREFIX_HINT="$(pg_dump_prefix_hint "${BACKUP_PATH}/db.dump")"
  rm -rf "${BACKUP_PATH}"
  if [[ -n "${PREFIX_HINT}" ]]; then
    log "The dump does not begin with the PGDMP magic of a PostgreSQL custom-format archive."
    log "It begins with: ${PREFIX_HINT}"
    die "Something wrote to the dump's stdout ahead of pg_dump. No backup was kept."
  fi
  die "pg_dump produced an empty file — check the output above for what it reported. No backup was kept."
fi

DB_SIZE=$(du -sh "${BACKUP_PATH}/db.dump" | cut -f1)
log "PostgreSQL backup complete (${DB_SIZE}), archive header verified."

# --- Vault public key metadata export ---
# Exports public keys only (fingerprints, algorithms, status). Private keys are
# never stored in the database and are NOT included in this export.

log "Exporting vault public key metadata..."
PUBKEY_SQL="COPY (SELECT key_id, public_key, algorithm, status, activated_at, retired_at FROM vault_signing_keys ORDER BY activated_at DESC) TO STDOUT WITH CSV HEADER"

if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  pg_client_run psql -c "${PUBKEY_SQL}" > "${BACKUP_PATH}/vault-public-keys.csv" 2>/dev/null || log "Vault key metadata export skipped (table may not exist)."
else
  "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" "${POSTGRES_DB}" -c "${PUBKEY_SQL}" > "${BACKUP_PATH}/vault-public-keys.csv" 2>/dev/null || log "Vault key metadata export skipped (table may not exist)."
fi

if [[ -f "${BACKUP_PATH}/vault-public-keys.csv" && -s "${BACKUP_PATH}/vault-public-keys.csv" ]]; then
  # Same hazard, same check: the first line of this file is COPY's header row.
  # Anything else in front of it means something logged onto the data stream.
  if [[ "$(head -1 "${BACKUP_PATH}/vault-public-keys.csv")" == key_id,* ]]; then
    log "Vault public key metadata exported."
  else
    log "WARN: vault-public-keys.csv does not start with the expected CSV header;"
    log "      its first line is: $(head -1 "${BACKUP_PATH}/vault-public-keys.csv" | head -c 200)"
    log "      Dropping it rather than keeping a corrupt export. The database dump is unaffected."
    rm -f "${BACKUP_PATH}/vault-public-keys.csv"
  fi
fi

# --- Create tarball ---

TARBALL="${BACKUP_ROOT}/backup-${TIMESTAMP}.tar.gz"
log "Creating tarball: ${TARBALL}"
tar -czf "${TARBALL}" -C "${BACKUP_ROOT}" "${TIMESTAMP}/"

TARBALL_SIZE=$(du -sh "${TARBALL}" | cut -f1)

# Remove the uncompressed backup directory
rm -rf "${BACKUP_PATH}"

# --- Cleanup old backups ---

log "Retaining last ${KEEP} backups..."
# shellcheck disable=SC2012
ls -1t "${BACKUP_ROOT}"/backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  log "Removing old backup: $(basename "${old}")"
  rm -f "${old}"
done

# --- Summary ---

echo ""
log "========================================="
log "Backup complete"
log "  File: ${TARBALL}"
log "  Size: ${TARBALL_SIZE}"
log "========================================="
