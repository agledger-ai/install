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
#   ./scripts/backup.sh --keep 14         # Keep last 14 backups (minimum 1)
#   BACKUP_DIR=/mnt/backups ./scripts/backup.sh  # Custom backup root
#
# Archives land in <this-checkout>/backup unless BACKUP_DIR says otherwise, and
# are named for the compose project, so two installs sharing one directory keep
# their own retention.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

KEEP=${KEEP:-7}
BACKUP_ROOT="$(backup_root)"
TIMESTAMP="$(date -u '+%Y-%m-%d-%H%M%S')"
# BACKUP_PATH is resolved once the compose project is known, below: the staging
# directory carries the project too, or two installs sharing one BACKUP_DIR on
# the same cron minute compute the same timestamp, write db.dump to the same
# path, and each archives whatever the other left there.
BACKUP_PATH=""

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --keep)
      [[ $# -ge 2 ]] || die "--keep needs a number, e.g. --keep 14"
      KEEP="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# The retention sweep at the bottom is `ls -1t | tail -n +$((KEEP + 1))`, which
# with KEEP=0 starts at line 1: it deletes every tarball in the directory,
# including the one this run just wrote and verified, and then reports a
# successful backup naming a file that no longer exists. An empty or
# non-numeric KEEP is worse still, because the arithmetic evaluates it as a
# variable name and can land anywhere. Retention is not the place to be
# permissive: refuse at parse time, before the dump runs.
if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -lt 1 ]]; then
  die "--keep must be a whole number of backups to retain, 1 or more (got '${KEEP}'). This run keeps the backup it takes, so 0 is not a retention policy: to remove backups, delete them from ${BACKUP_ROOT}."
fi

load_env
detect_db_mode
build_compose_cmd

# The compose project is this install's identity: containers, network and
# volume all hang off it, and it is what distinguishes two stacks on one host.
# It goes in the archive name so a shared BACKUP_DIR does not let one install's
# retention sweep reach another's files.
BACKUP_PROJECT="$(compose_project_name)"
BACKUP_PATH="${BACKUP_ROOT}/${BACKUP_PROJECT}-${TIMESTAMP}"

report_legacy_backup_root

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

# --- Record what this backup came from ---
#
# The version, so a restore can put the install back on it. Without this file a
# rollback restored the data and left the install on the release it was rolling
# back FROM, with that release's migrations re-applied over the older dump, and
# nothing in either run said so.
#
# Read from .env rather than from the running container, because .env is what a
# restart uses, and it is also what upgrade.sh has not yet rewritten when it
# takes its pre-upgrade backup. The pin travels with it so a rollback lands on
# the same bytes, digest and all, instead of re-resolving a tag.
#
# An install that never recorded a version writes the keys empty; restore.sh
# treats that as unknown and says so rather than guessing.
METADATA_FILE="${BACKUP_PATH}/backup-metadata"
{
  echo "# AGLedger backup metadata. Written by backup.sh, read by restore.sh."
  echo "created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "compose_project=${BACKUP_PROJECT}"
  echo "agledger_version=$(get_env_value AGLEDGER_VERSION "${COMPOSE_DIR}/.env")"
  echo "agledger_image_pin=$(get_env_value AGLEDGER_IMAGE_PIN "${COMPOSE_DIR}/.env")"
} > "${METADATA_FILE}"
log "Recorded install metadata (version, image pin, project)."

# --- Create tarball ---

TARBALL="${BACKUP_ROOT}/backup-${BACKUP_PROJECT}-${TIMESTAMP}.tar.gz"
log "Creating tarball: ${TARBALL}"
tar -czf "${TARBALL}" -C "${BACKUP_ROOT}" "${BACKUP_PROJECT}-${TIMESTAMP}/"

TARBALL_SIZE=$(du -sh "${TARBALL}" | cut -f1)

# Remove the uncompressed backup directory
rm -rf "${BACKUP_PATH}"

# --- Cleanup old backups ---

log "Retaining last ${KEEP} backups for project ${BACKUP_PROJECT}..."
# Scoped to this project's archives. Unscoped, a `--keep` run in one checkout
# deleted the pre-upgrade archive another install had just taken, which is the
# one archive whose loss cannot be noticed until the rollback that needs it.
# Archives from earlier releases carry no project in their name and are left
# alone for the same reason.
#
# The timestamp is spelled out digit by digit rather than as `*`, because one
# project name can be a prefix of another: `agledger` and the README's own
# `agledger-2` both sit under `backup-agledger-`, and a trailing `*` in the
# first install's sweep matches every archive of the second. A `-` cannot
# separate them (a compose project name may contain one), but a date can: only
# this project's name is followed immediately by `YYYY-MM-DD-HHMMSS`.
# shellcheck disable=SC2012
#
# `|| true` because the archive is already written by the time this runs. `ls`
# exits 2 on a pattern it cannot match, which `pipefail` carries out of the
# pipeline and `set -e` turns into a failed run: a BACKUP_DIR carrying a glob
# metacharacter would report "Backup failed" to upgrade.sh, and abort the
# upgrade, over a backup that is sitting on disk and complete.
{ ls -1t "${BACKUP_ROOT}/backup-${BACKUP_PROJECT}"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz 2>/dev/null || true; } | tail -n +$((KEEP + 1)) | while read -r old; do
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
