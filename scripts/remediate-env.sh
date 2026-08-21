#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — .env Remediation Script
# =============================================================================
# Applies the missing-COMPOSE_FILE fix to an existing .env. Safe to run
# multiple times.
#
# Context: v0.19.16 shipped an install.sh that omitted COMPOSE_FILE. v0.19.17
# fixed the fresh-install path but did not rewrite existing .env files. This
# script closes that gap for customers who installed at v0.19.16 and have since
# upgraded.
#
# Usage:
#   ./scripts/remediate-env.sh
#   ./scripts/remediate-env.sh --non-interactive
#   ./scripts/remediate-env.sh --dry-run
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
[[ -f "$ENV_FILE" ]] || fatal "No .env at ${ENV_FILE}. Run ./scripts/install.sh first."

load_env
detect_db_mode

# --- Build the list of proposed changes ---

PROPOSED=()

# Missing COMPOSE_FILE
if ! grep -qE '^COMPOSE_FILE=' "$ENV_FILE" 2>/dev/null; then
  build_overlay_list
  PROPOSED+=("COMPOSE_FILE|add|COMPOSE_FILE=${OVERLAY_LIST}|${OVERLAY_LIST}")
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
    COMPOSE_FILE)
      upsert_env_var COMPOSE_FILE "${value}" "$ENV_FILE"
      info "[COMPOSE_FILE] Added ${summary}"
      ;;
    *)
      # A tag added to PROPOSED without an apply arm would print its plan
      # line and then silently do nothing. Fail loudly so the gap is a
      # script error, not a no-op the operator trusts.
      fatal "remediate-env.sh: no apply arm for proposed change '${tag}' (${action} ${summary}). This is a script bug."
      ;;
  esac
done

echo ""
info "Remediation complete. Restart services to pick up COMPOSE_FILE changes if applicable:"
info "  docker compose down && docker compose up -d"
