#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — .env Remediation Script
# =============================================================================
# Applies the F-408 (REGISTRATION_ENABLED=true default) and F-410
# (missing COMPOSE_FILE) fixes to an existing .env. Safe to run multiple times.
#
# Context: v0.19.16 shipped an install.sh that left REGISTRATION_ENABLED=true
# and omitted COMPOSE_FILE. v0.19.17 fixed the fresh-install path but did not
# rewrite existing .env files. This script closes that gap for customers who
# installed at v0.19.16 and have since upgraded. (F-415)
#
# Usage:
#   ./deploy/scripts/remediate-env.sh
#   ./deploy/scripts/remediate-env.sh --non-interactive
#   ./deploy/scripts/remediate-env.sh --dry-run
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--non-interactive] [--dry-run]"
      echo ""
      echo "Options:"
      echo "  --non-interactive    Apply fixes without prompting"
      echo "  --dry-run            Show what would change without modifying .env"
      echo "  -h, --help           Show this help"
      exit 0
      ;;
    *) fatal "Unknown argument: $1" ;;
  esac
done

ENV_FILE="${COMPOSE_DIR}/.env"
[[ -f "$ENV_FILE" ]] || fatal "No .env at ${ENV_FILE}. Run install.sh first."

load_env
detect_db_mode

# --- Build the list of proposed changes ---

PROPOSED=()

# F-410: missing COMPOSE_FILE
if ! grep -qE '^COMPOSE_FILE=' "$ENV_FILE" 2>/dev/null; then
  OVERLAY_LIST="docker-compose.yml"
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.postgres.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.postgres.yml"
  fi
  if [[ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.prod.yml"
  fi
  PROPOSED+=("F-410|add|COMPOSE_FILE=${OVERLAY_LIST}|${OVERLAY_LIST}")
fi

# F-408: REGISTRATION_ENABLED=true without opt-in marker
REG_STATE=$(grep -E '^REGISTRATION_ENABLED=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ "$REG_STATE" == "true" ]] && ! grep -qE '^# AGLEDGER_REGISTRATION_INTENTIONAL' "$ENV_FILE" 2>/dev/null; then
  PROPOSED+=("F-408|set|REGISTRATION_ENABLED=false|false")
fi

if [[ ${#PROPOSED[@]} -eq 0 ]]; then
  info "No remediation needed — .env is already consistent with current defaults."
  exit 0
fi

# --- Show the plan ---

echo ""
echo "Proposed changes to ${ENV_FILE}:"
echo ""
for p in "${PROPOSED[@]}"; do
  tag=${p%%|*}
  rest=${p#*|}
  action=${rest%%|*}
  rest=${rest#*|}
  summary=${rest%%|*}
  case "$action" in
    add) echo "  [${tag}] ADD:  ${summary}" ;;
    set) echo "  [${tag}] SET:  ${summary}" ;;
  esac
done
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  info "--dry-run specified. No changes written."
  exit 0
fi

# --- Confirm ---

if [[ "$NON_INTERACTIVE" != "true" ]]; then
  if [[ ! -t 0 ]]; then
    log_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "[${log_ts}] Non-TTY stdin detected — proceeding as if --non-interactive was passed." >&2
  else
    read -rp "Apply these changes? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      echo "Aborted. No changes made."
      exit 0
    fi
  fi
fi

# --- Apply ---

for p in "${PROPOSED[@]}"; do
  tag=${p%%|*}
  rest=${p#*|}
  action=${rest%%|*}
  rest=${rest#*|}
  summary=${rest%%|*}
  value=${rest#*|}
  case "$tag" in
    F-410)
      upsert_env_var COMPOSE_FILE "${value}" "$ENV_FILE"
      info "[F-410] Added ${summary}"
      ;;
    F-408)
      upsert_env_var REGISTRATION_ENABLED "false" "$ENV_FILE"
      info "[F-408] Set REGISTRATION_ENABLED=false"
      ;;
  esac
done

echo ""
info "Remediation complete. Restart services to pick up COMPOSE_FILE changes if applicable:"
info "  docker compose down && docker compose up -d"
