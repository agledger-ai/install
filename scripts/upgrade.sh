#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Upgrade Script
# =============================================================================
# Usage:
#   ./deploy/scripts/upgrade.sh 1.3.0
#   ./deploy/scripts/upgrade.sh 1.3.0 --skip-backup
# =============================================================================

# --- Shared Helpers ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"

cleanup() {
  if [[ $? -ne 0 ]]; then
    echo ""
    error "Upgrade failed. Your previous version should still be running."
    error "Check: docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
    error "Logs:  docker compose -f ${COMPOSE_DIR}/docker-compose.yml logs"
  fi
}
trap cleanup EXIT

handle_sigint() {
  echo ""
  warn "Upgrade interrupted by user."
  warn "Your services may be in a mixed state. Check: docker compose ps"
  exit 130
}
trap handle_sigint INT

# --- Argument Parsing ---

TARGET_VERSION=""
SKIP_BACKUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-backup)
      SKIP_BACKUP=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <TARGET_VERSION> [OPTIONS]"
      echo ""
      echo "Arguments:"
      echo "  TARGET_VERSION       Version to upgrade to (required, e.g., 1.3.0)"
      echo ""
      echo "Options:"
      echo "  --skip-backup        Skip pre-upgrade backup (not recommended)"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    -*)
      fatal "Unknown option: $1 (use --help for usage)"
      ;;
    *)
      if [[ -z "$TARGET_VERSION" ]]; then
        TARGET_VERSION="$1"
      else
        fatal "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$TARGET_VERSION" ]]; then
  fatal "Target version is required. Usage: $0 <VERSION> [--skip-backup]"
fi

# --- Resolve Current Version ---

step "Checking current version"

ENV_FILE="${COMPOSE_DIR}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  fatal "No .env file found at ${ENV_FILE}. Is AGLedger installed?"
fi

# Source .env for DATABASE_URL detection
# shellcheck disable=SC1090
source "$ENV_FILE"

CURRENT_VERSION=""

# Try .env first
if grep -q 'AGLEDGER_VERSION=' "$ENV_FILE" 2>/dev/null; then
  CURRENT_VERSION=$(grep 'AGLEDGER_VERSION=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '[:space:]')
fi

# Fall back to package.json
if [[ -z "$CURRENT_VERSION" ]]; then
  CURRENT_VERSION=$(resolve_version)
fi

# Fall back to docker inspect
if [[ -z "$CURRENT_VERSION" ]]; then
  CURRENT_VERSION=$(docker inspect --format '{{.Config.Image}}' \
    "$(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps -q agledger-api 2>/dev/null | head -1)" 2>/dev/null \
    | grep -oP '(?<=:)[^:]+$' || echo "unknown")
fi

info "Current version: ${CURRENT_VERSION}"
info "Target version:  ${TARGET_VERSION}"

# --- Detect removed env vars (v0.15.0+) ---

if grep -q '^[[:space:]]*\(export[[:space:]]\+\)\?AGLEDGER_LICENSE_MODE[[:space:]]*=' "$ENV_FILE" 2>/dev/null; then
  warn "AGLEDGER_LICENSE_MODE is removed in v0.15.0 — the server will refuse to start if it is set."
  warn "Commenting it out in ${ENV_FILE}."
  sedi 's/^\([[:space:]]*\)\(export[[:space:]]\+\)\?\(AGLEDGER_LICENSE_MODE[[:space:]]*=\)/#REMOVED_v0.15# \1\2\3/' "$ENV_FILE"
  info "AGLEDGER_LICENSE_MODE commented out. Licensing is now automatic when a license key is present."
fi

# --- Clean up stale AGLEDGER_RELEASE_DATE from .env ---
# AGLEDGER_RELEASE_DATE is baked into the Docker image at build time.
if grep -q '^AGLEDGER_RELEASE_DATE=' "$ENV_FILE" 2>/dev/null; then
  sedi 's/^AGLEDGER_RELEASE_DATE=/#REMOVED# AGLEDGER_RELEASE_DATE=/' "$ENV_FILE"
  info "Commented out AGLEDGER_RELEASE_DATE in .env (image-baked value takes precedence)"
fi

if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
  warn "Already running version ${TARGET_VERSION}. Nothing to do."
  exit 0
fi

# --- Detect Database Mode ---

detect_db_mode

# --- Configuration State Check ---
# Surface known-broken-state conditions from v0.19.16 before the customer
# confirms. Don't auto-flip security-sensitive values. (F-415)

step "Checking configuration state"

REG_STATE=$(grep -E '^REGISTRATION_ENABLED=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ "$REG_STATE" == "true" ]] && ! grep -qE '^# AGLEDGER_REGISTRATION_INTENTIONAL' "$ENV_FILE" 2>/dev/null; then
  warn "REGISTRATION_ENABLED=true in .env — exposes open signup at POST /v1/auth/enterprise."
  warn "v0.19.16 installed this by accident; v0.19.17+ ships with it disabled. (F-408)"
  warn "If intentional, add '# AGLEDGER_REGISTRATION_INTENTIONAL=1' to .env to silence."
  warn "To remediate: run ./scripts/remediate-env.sh after the upgrade."
fi

if ! grep -qE '^COMPOSE_FILE=' "$ENV_FILE" 2>/dev/null; then
  warn "COMPOSE_FILE not persisted in .env — manual 'docker compose' commands will drop overlays."
  warn "Auto-adding based on current deployment (F-410 fix)."
  OVERLAY_LIST="docker-compose.yml"
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.postgres.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.postgres.yml"
  fi
  if [[ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.prod.yml"
  fi
  upsert_env_var COMPOSE_FILE "${OVERLAY_LIST}" "$ENV_FILE"
  info "Added COMPOSE_FILE=${OVERLAY_LIST}"
fi

# --- Confirmation ---

echo ""
echo -e "${YELLOW}Upgrade AGLedger from ${BOLD}${CURRENT_VERSION}${NC}${YELLOW} to ${BOLD}${TARGET_VERSION}${NC}${YELLOW}?${NC}"

if [[ -t 0 ]]; then
  read -rp "Continue? (y/N) " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled."
    exit 0
  fi
else
  info "Non-interactive mode detected. Proceeding with upgrade."
fi

# --- Pre-Upgrade Backup ---

step "Pre-upgrade backup"

if [[ "$SKIP_BACKUP" == true ]]; then
  warn "Backup skipped (--skip-backup). This is NOT recommended for production."
else
  if [[ -x "$BACKUP_SCRIPT" ]]; then
    info "Running backup..."
    "$BACKUP_SCRIPT" || fatal "Backup failed. Fix the issue or use --skip-backup to proceed without a backup (not recommended)."
    info "Backup complete"
  else
    warn "Backup script not found at ${BACKUP_SCRIPT}."
    warn "Proceeding without backup."
  fi
fi

# Save pre-upgrade version for rollback
BACKUP_ROOT="${BACKUP_DIR:-${REPO_ROOT}/backup}"
if [[ -d "$BACKUP_ROOT" ]] && [[ -n "$CURRENT_VERSION" ]]; then
  echo "$CURRENT_VERSION" > "${BACKUP_ROOT}/.pre-upgrade-version"
fi

# --- Image Registry ---

if [[ "${AGLEDGER_IMAGE}" != "agledger/agledger" ]]; then
  step "Authenticating with private registry"
  ecr_login
fi

# --- Pull New Image ---

step "Pulling new image"

docker pull "${AGLEDGER_IMAGE}:${TARGET_VERSION}" \
  || fatal "Failed to pull ${AGLEDGER_IMAGE}:${TARGET_VERSION}. Check the version exists."
info "Pulled ${AGLEDGER_IMAGE}:${TARGET_VERSION}"

# --- Stop Worker ---

step "Stopping worker (prevent job processing during migration)"

build_compose_cmd
"${COMPOSE[@]}" stop agledger-worker 2>/dev/null || true
info "Worker stopped"

# --- Run Migrations ---

step "Running database migrations with new image"

AGLEDGER_VERSION="${TARGET_VERSION}" "${COMPOSE[@]}" run --rm agledger-migrate
info "Migrations complete"

# --- Update Version in .env ---

step "Updating configuration"

upsert_env_var AGLEDGER_VERSION "${TARGET_VERSION}" "$ENV_FILE"
info "Updated AGLEDGER_VERSION=${TARGET_VERSION} in .env"

# --- Restart All Services ---

step "Restarting all services"

"${COMPOSE[@]}" up -d
info "All services restarted"

# --- Preflight Check ---

step "Running preflight checks"

ELAPSED=0
MAX_WAIT=30
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  if "${COMPOSE[@]}" exec agledger-api /nodejs/bin/node -e \
    "fetch('http://localhost:3000/health').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))" \
    2>/dev/null; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "API did not become ready within ${MAX_WAIT}s. Continuing with checks..."
fi

"${COMPOSE[@]}" exec agledger-api /nodejs/bin/node dist/scripts/preflight.js 2>&1 || {
  warn "Preflight checks returned warnings (non-fatal)."
}

# --- Version Verification ---

step "Verifying upgrade"

HEALTH_RESPONSE=$("${COMPOSE[@]}" exec agledger-api /nodejs/bin/node -e \
  "fetch('http://localhost:3000/health').then(r=>r.json()).then(d=>console.log(JSON.stringify(d))).catch(e=>console.error(e))" \
  2>/dev/null || echo "{}")

HEALTH_VERSION=$(echo "$HEALTH_RESPONSE" | grep -oP '"version"\s*:\s*"[^"]*"' | grep -oP '(?<=")[^"]+(?="$)' || echo "unknown")
if [[ "$HEALTH_VERSION" == "$TARGET_VERSION" ]]; then
  info "/health reports version: ${HEALTH_VERSION}"
elif [[ "$HEALTH_VERSION" != "unknown" ]]; then
  warn "/health reports version ${HEALTH_VERSION}, expected ${TARGET_VERSION}"
else
  warn "Could not verify version from /health endpoint"
fi

# --- Summary ---

echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN}  AGLedger — Upgrade Complete${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo -e "  ${BOLD}Previous version:${NC}  ${CURRENT_VERSION}"
echo -e "  ${BOLD}Current version:${NC}   ${TARGET_VERSION}"
echo ""
echo -e "  ${BOLD}Verify:${NC}"
echo -e "    curl -s http://localhost:3001/health | jq ."
echo -e "    docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
echo ""
echo -e "${GREEN}=============================================================================${NC}"
