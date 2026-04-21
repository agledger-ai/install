#!/usr/bin/env bash
# =============================================================================
# AGLedger — Shared Deployment Helpers
# =============================================================================
# Source this from scripts that need compose commands, logging, or ECR auth.
# Automatically resolves paths relative to this script's location.
# =============================================================================

# Resolve paths relative to deploy/ directory
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
COMPOSE_DIR="${DEPLOY_DIR}/compose"

# --- Constants ---

AGLEDGER_IMAGE="${AGLEDGER_IMAGE:-agledger/agledger}"

# Private registry override (set ECR_REGISTRY for internal/air-gap registries)
ECR_REGISTRY="${ECR_REGISTRY:-}"

# --- macOS Compatibility ---

# macOS-compatible sed -i (GNU sed vs BSD sed)
sedi() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# Set KEY=VALUE in an env file: replace the line if KEY exists, append if not.
# Usage: upsert_env_var KEY VALUE FILE
upsert_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -q "^${key}=" "$file"; then
    sedi "s|^${key}=.*|${key}=${value}|" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# --- Colors & Logging ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ts() { date '+%Y-%m-%d %H:%M:%S'; }
info()    { echo -e "$(ts) ${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "$(ts) ${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "$(ts) ${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n$(ts) ${BLUE}[STEP]${NC}  ${BOLD}$*${NC}"; }
fatal()   { error "$*"; exit 1; }

# --- ECR Authentication ---

ecr_login() {
  if [[ -z "$ECR_REGISTRY" ]]; then
    warn "ECR_REGISTRY not set. Set it to authenticate with a private registry."
    return
  fi
  if command -v aws &>/dev/null; then
    local region="${AWS_REGION:-us-west-2}"
    if aws ecr get-login-password --region "$region" 2>/dev/null | docker login --username AWS --password-stdin "$ECR_REGISTRY" 2>/dev/null; then
      info "Authenticated with ECR (${ECR_REGISTRY})"
    else
      warn "ECR login failed. If using an air-gap bundle, this is expected."
    fi
  else
    warn "AWS CLI not found. Skipping ECR login."
  fi
}

# --- Version Resolution ---

resolve_version() {
  # Try .env first (set during install)
  if [[ -f "${COMPOSE_DIR}/.env" ]] && grep -q 'AGLEDGER_VERSION=' "${COMPOSE_DIR}/.env" 2>/dev/null; then
    grep 'AGLEDGER_VERSION=' "${COMPOSE_DIR}/.env" | head -1 | cut -d= -f2- | tr -d '[:space:]'
    return
  fi
  # Fall back to package.json (dev environment only — no Node.js dependency for customers)
  if command -v node &>/dev/null && [[ -f "${REPO_ROOT}/package.json" ]]; then
    node -p "require('${REPO_ROOT}/package.json').version" 2>/dev/null || echo "latest"
    return
  fi
  echo "latest"
}

# Poll a URL until it returns HTTP 2xx, up to a bounded number of attempts.
# Returns 0 on first success, 1 if the deadline passes.
#
# Usage: wait_for_http <url> [max_attempts=5] [sleep_seconds=2]
wait_for_http() {
  local url="$1"
  local max_attempts="${2:-5}"
  local sleep_seconds="${3:-2}"
  for _ in $(seq 1 "$max_attempts"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep "$sleep_seconds"
  done
  return 1
}

# Resolve the latest stable version from Docker Hub tags API.
# Prints the semver string (e.g., "0.19.13") to stdout on success.
# Returns non-zero if the network call fails AND no usable cache exists.
# Cache: ${HOME}/.cache/agledger/latest-version, 1 hour TTL, falls back to
# stale cache if the API is unreachable — and warns on stderr with the age.
resolve_latest_version() {
  local cache_dir="${HOME}/.cache/agledger"
  local cache_file="${cache_dir}/latest-version"
  local cache_max_age=3600
  local cache_age=""

  if [[ -f "$cache_file" ]]; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file") ))
    else
      cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file") ))
    fi
    if [[ $cache_age -lt $cache_max_age ]]; then
      cat "$cache_file"
      return 0
    fi
  fi

  local api_url="https://hub.docker.com/v2/repositories/agledger/agledger/tags?page_size=100"
  local tags_json
  if tags_json=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null); then
    local latest
    latest=$(echo "$tags_json" \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -V \
      | tail -1)
    if [[ -n "$latest" ]]; then
      mkdir -p "$cache_dir"
      echo "$latest" > "$cache_file"
      echo "$latest"
      return 0
    fi
  fi

  if [[ -f "$cache_file" ]]; then
    local age_min=$(( ${cache_age:-0} / 60 ))
    # Warn to stderr (keeping stdout clean for the version string). Agents
    # piping this call into a variable still get the version back — they just
    # also see the warning, which is the point. (F-397)
    echo "WARN: Docker Hub unreachable; using cached latest-version (age: ~${age_min} min). Pin with --version X.Y.Z to be explicit, or check network and retry." >&2
    cat "$cache_file"
    return 0
  fi

  return 1
}

# Source .env if present. Sets POSTGRES_USER, POSTGRES_DB, DATABASE_URL, etc.
load_env() {
  if [[ -f "${COMPOSE_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${COMPOSE_DIR}/.env"
  fi
  POSTGRES_USER="${POSTGRES_USER:-agledger}"
  POSTGRES_DB="${POSTGRES_DB:-agledger}"
}

# Detect whether DATABASE_URL points to the bundled postgres or an external host.
# Sets USES_BUNDLED_PG=true (bundled) or USES_BUNDLED_PG=false (external).
detect_db_mode() {
  USES_BUNDLED_PG=true
  if [[ -n "${DATABASE_URL:-}" ]]; then
    # Match only exact bundled hostnames followed by a port number.
    # This avoids false-positives on hosts like postgres-prod.rds.amazonaws.com.
    if ! echo "${DATABASE_URL}" | grep -qE '@(postgres|localhost|127\.0\.0\.1):[0-9]'; then
      USES_BUNDLED_PG=false
    fi
  fi
}

# Build COMPOSE array with the correct -f flags for the current deployment.
# Uses bash arrays (not word-split strings) per project conventions.
build_compose_cmd() {
  local compose_file="${COMPOSE_DIR}/docker-compose.yml"
  local postgres_file="${COMPOSE_DIR}/docker-compose.postgres.yml"
  local prod_file="${COMPOSE_DIR}/docker-compose.prod.yml"

  if docker compose version &>/dev/null 2>&1; then
    COMPOSE=(docker compose -f "${compose_file}")
  else
    COMPOSE=(docker-compose -f "${compose_file}")
  fi

  if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -f "${postgres_file}" ]]; then
    COMPOSE+=(-f "${postgres_file}")
  fi

  if [[ -f "${prod_file}" ]]; then
    COMPOSE+=(-f "${prod_file}")
  fi
}
