#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Uninstaller
# =============================================================================
# Stops all containers and removes Docker volumes. By default .env is kept so
# you can reinstall without regenerating secrets; pass --purge to remove it.
#
# Usage:
#   ./uninstall.sh
#   ./uninstall.sh --non-interactive
#   ./uninstall.sh --purge
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false
PURGE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --purge)
      PURGE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [--non-interactive] [--purge]"
      echo ""
      echo "Options:"
      echo "  --non-interactive    Skip the confirmation prompt"
      echo "  --purge              Also remove .env (secrets will be regenerated on reinstall)"
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
    echo "--purge: ${ENV_FILE} will also be removed."
  else
    echo "${ENV_FILE} will be kept so secrets survive a reinstall."
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
    rm -f "$ENV_FILE"
    info "Removed ${ENV_FILE}"
  fi
fi

echo ""
echo "AGLedger uninstalled."
if [[ "$PURGE" != "true" && -f "$ENV_FILE" ]]; then
  echo "Secrets are preserved in ${ENV_FILE}. Run install.sh to reinstall."
fi
