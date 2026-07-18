#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Uninstaller
# =============================================================================
# Stops all containers and removes Docker volumes. By default .env is kept so
# you can reinstall without regenerating secrets; pass --purge to remove it.
#
# --purge does NOT delete .env outright: .env holds VAULT_SIGNING_KEY, the
# Ed25519 key every record signature chains to, so purge writes a timestamped
# backup of .env before removing it. Destroying that key is a non-recoverable
# event (past signed records can no longer be verified against a live key, and
# the chain cannot be extended under the same identity), so recovery stays one
# step away even on an automated purge.
#
# Usage:
#   ./uninstall.sh
#   ./uninstall.sh --non-interactive   (alias: -y, --yes)
#   ./uninstall.sh --purge
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false
PURGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --purge)
      PURGE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-y|--yes|--non-interactive] [--purge]"
      echo ""
      echo "Options:"
      echo "  -y, --yes,           Skip the confirmation prompt"
      echo "  --non-interactive"
      echo "  --purge              Also remove .env, after saving a timestamped backup"
      echo "                       (.env holds VAULT_SIGNING_KEY; secrets regenerate on reinstall)"
      echo "  -h, --help           Show this help"
      exit 0
      ;;
    *)
      fatal "Unknown argument: $1"
      ;;
  esac
done

ENV_FILE="${COMPOSE_DIR}/.env"

if [[ "$NON_INTERACTIVE" != "true" ]]; then
  echo "This will stop all AGLedger containers and delete Docker volumes."
  echo "All data in the bundled database will be destroyed. External databases are untouched."
  if [[ "$PURGE" == "true" ]]; then
    echo "--purge: ${ENV_FILE} will be removed (a timestamped backup is saved first)."
    echo ""
    echo "WARNING: ${ENV_FILE} holds VAULT_SIGNING_KEY, the Ed25519 key every record"
    echo "signature chains to. Without it you cannot verify existing signed records"
    echo "against a live key or extend the chain under the same identity. The backup"
    echo "still contains that key: store it securely, or shred it if you intend to"
    echo "destroy the key permanently."
  else
    echo "${ENV_FILE} will be kept so secrets survive a reinstall."
  fi
  # Fail loud when stdin isn't a TTY — otherwise `read` returns empty, confirm
  # is empty, and we silently abort with exit 0 (looks like success in
  # automation logs). (F-399)
  if [[ ! -t 0 ]]; then
    echo "ERROR: uninstall prompt requires an interactive TTY. Re-run with --non-interactive to skip the prompt." >&2
    exit 2
  fi
  read -rp "Continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

load_env
detect_db_mode
build_compose_cmd

step "Stopping containers and removing volumes"
"${COMPOSE[@]}" down -v --remove-orphans
info "Containers and volumes removed"

if [[ "$PURGE" == "true" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # Back up before removal so destroying VAULT_SIGNING_KEY (which .env holds)
    # is never a one-way door. Runs on both interactive and --non-interactive
    # purges, so an automated teardown can still recover the chain-signing key.
    BACKUP_FILE="${ENV_FILE}.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$ENV_FILE" "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE" 2>/dev/null || true
    rm -f "$ENV_FILE"
    info "Removed ${ENV_FILE} (backup saved to ${BACKUP_FILE})"
    warn "${BACKUP_FILE} still contains VAULT_SIGNING_KEY. Store it securely, or shred it to destroy the key permanently."
  fi
fi

echo ""
echo "AGLedger uninstalled."
if [[ "$PURGE" != "true" && -f "$ENV_FILE" ]]; then
  echo "Secrets are preserved in ${ENV_FILE}. Run install.sh to reinstall."
fi
