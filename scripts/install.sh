#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — First-Run Installer
# =============================================================================
# Usage:
#   ./install.sh
#   ./install.sh --version 0.15.6
#   ./install.sh --non-interactive --version 0.15.6 --with-monitoring
#   ./install.sh --external-db --non-interactive
#   ./install.sh --image your-registry.com/agledger --version 0.15.6
#
# Supported: Ubuntu 22.04+, macOS 14+ (amd64 only — Apple Silicon via Rosetta)
# =============================================================================

# --- Shared Helpers ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

HEALTHCHECK_TIMEOUT=30

cleanup() {
  if [[ $? -ne 0 ]]; then
    echo ""
    error "Installation failed. Check the output above for details."
    error "You can re-run this script after fixing the issue."
  fi
}
trap cleanup EXIT

handle_sigint() {
  echo ""
  warn "Installation interrupted by user."
  exit 130
}
trap handle_sigint INT

# --- Argument Parsing ---

export NON_INTERACTIVE=false
WITH_MONITORING=false
REQUESTED_VERSION=""
EXTERNAL_DB_FLAG=false
CUSTOM_IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --version)
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    --image)
      CUSTOM_IMAGE="$2"
      shift 2
      ;;
    --with-monitoring)
      WITH_MONITORING=true
      shift
      ;;
    --external-db)
      EXTERNAL_DB_FLAG=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --non-interactive    Skip all prompts (use defaults)"
      echo "  --version VERSION    AGLedger version to install (default: latest stable from Docker Hub)"
      echo "  --image IMAGE        Container image (default: agledger/agledger)"
      echo "  --with-monitoring    Enable monitoring stack (Jaeger, Prometheus, Grafana)"
      echo "  --external-db        Skip bundled PostgreSQL (DATABASE_URL must be set in .env)"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *)
      fatal "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

# Override image if --image was provided
if [[ -n "$CUSTOM_IMAGE" ]]; then
  AGLEDGER_IMAGE="$CUSTOM_IMAGE"
fi

# --- OS Detection ---

step "Checking platform"

OS_NAME="$(uname -s)"
case "$OS_NAME" in
  Linux)
    if [[ -f /etc/os-release ]]; then
      # shellcheck disable=SC1091
      source /etc/os-release
      if [[ "${ID:-}" == "ubuntu" ]]; then
        UBUNTU_MAJOR=$(echo "${VERSION_ID:-0}" | cut -d. -f1)
        if [[ "$UBUNTU_MAJOR" -lt 22 ]]; then
          warn "Ubuntu ${VERSION_ID} detected. Ubuntu 22.04+ recommended."
        else
          info "Ubuntu ${VERSION_ID}"
        fi
      else
        info "Linux (${PRETTY_NAME:-$ID})"
      fi
    else
      info "Linux"
    fi
    ;;
  Darwin)
    MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null || echo "0.0")
    MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d. -f1)
    if [[ "$MACOS_MAJOR" -lt 14 ]]; then
      warn "macOS ${MACOS_VERSION} detected. macOS 14+ recommended."
    else
      info "macOS ${MACOS_VERSION}"
    fi
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
      warn "Apple Silicon detected — Docker runs amd64 images under Rosetta. Performance may vary."
    fi
    ;;
  *)
    warn "Unsupported OS: ${OS_NAME}. See manual install docs."
    ;;
esac

# --- Prerequisites ---

step "Checking prerequisites"

# Docker Engine 24+
if ! command -v docker &>/dev/null; then
  fatal "Docker Engine is not installed. Install Docker: https://docs.docker.com/engine/install/"
fi

DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
DOCKER_MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)
if [[ "$DOCKER_MAJOR" -lt 24 ]]; then
  fatal "Docker Engine 24+ required (found: ${DOCKER_VERSION}). Upgrade: https://docs.docker.com/engine/install/"
fi
info "Docker Engine ${DOCKER_VERSION}"

# Docker Compose v2
if ! docker compose version &>/dev/null; then
  fatal "Docker Compose v2 is not installed. Install: https://docs.docker.com/compose/install/"
fi
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "0.0.0")
COMPOSE_MAJOR=$(echo "$COMPOSE_VERSION" | cut -d. -f1)
if [[ "$COMPOSE_MAJOR" -lt 2 ]]; then
  fatal "Docker Compose v2+ required (found: ${COMPOSE_VERSION})"
fi
info "Docker Compose ${COMPOSE_VERSION}"

# jq (used for JSON parsing during install)
if ! command -v jq &>/dev/null; then
  fatal "jq is not installed. Install: sudo apt-get install -y jq (or brew install jq)"
fi

# curl (used for Docker Hub tag lookup and demo-seed API calls)
if ! command -v curl &>/dev/null; then
  fatal "curl is not installed. Install: sudo apt-get install -y curl (or brew install curl)"
fi

# openssl (used for secret generation)
if ! command -v openssl &>/dev/null; then
  fatal "openssl is not installed. Install: sudo apt-get install -y openssl"
fi

# RAM check (4 GB minimum)
if command -v free &>/dev/null; then
  TOTAL_RAM_KB=$(free -k | awk '/^Mem:/ {print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  if [[ "$TOTAL_RAM_KB" -lt 3800000 ]]; then
    fatal "At least 4 GB of RAM required (found: ~${TOTAL_RAM_GB} GB)"
  fi
  info "RAM: ~${TOTAL_RAM_GB} GB"
elif [[ "$OS_NAME" == "Darwin" ]]; then
  TOTAL_RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo "0")
  TOTAL_RAM_GB=$((TOTAL_RAM_BYTES / 1024 / 1024 / 1024))
  if [[ "$TOTAL_RAM_GB" -lt 4 ]]; then
    fatal "At least 4 GB of RAM required (found: ~${TOTAL_RAM_GB} GB)"
  fi
  info "RAM: ~${TOTAL_RAM_GB} GB"
elif [[ -f /proc/meminfo ]]; then
  TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
  if [[ "$TOTAL_RAM_KB" -lt 3800000 ]]; then
    fatal "At least 4 GB of RAM required (found: ~${TOTAL_RAM_GB} GB)"
  fi
  info "RAM: ~${TOTAL_RAM_GB} GB"
else
  warn "Cannot determine available RAM. Ensure at least 4 GB is available."
fi

# CPU check (2 cores minimum)
CPU_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "0")
if [[ "$CPU_CORES" -lt 2 ]]; then
  fatal "At least 2 CPU cores required (found: ${CPU_CORES})"
fi
info "CPU cores: ${CPU_CORES}"

# --- Version Resolution ---

step "Resolving version"

if [[ -n "$REQUESTED_VERSION" ]]; then
  AGLEDGER_VERSION="$REQUESTED_VERSION"
  info "Version: ${AGLEDGER_VERSION} (requested)"
else
  info "Looking up latest version from Docker Hub..."
  if ! AGLEDGER_VERSION=$(resolve_latest_version); then
    fatal "Could not determine latest version (network failure, no cache). Re-run with --version X.Y.Z to pin a specific release. See https://hub.docker.com/r/agledger/agledger/tags"
  fi
  info "Version: ${AGLEDGER_VERSION} (latest from Docker Hub)"
fi

# --- Image Registry ---

if [[ "${AGLEDGER_IMAGE}" != "agledger/agledger" ]]; then
  step "Authenticating with private registry"
  ecr_login
else
  info "Using Docker Hub: ${AGLEDGER_IMAGE}"
fi

# --- Environment Configuration ---

step "Configuring environment"

ENV_FILE="${COMPOSE_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists at ${ENV_FILE} — skipping secret generation."
  warn "Delete it and re-run if you want a fresh configuration."
else
  if [[ -f "${COMPOSE_DIR}/.env.example" ]]; then
    info "Copying .env.example to .env"
    cp "${COMPOSE_DIR}/.env.example" "$ENV_FILE"
  else
    info "Creating minimal .env"
    cat > "$ENV_FILE" <<ENVEOF
AGLEDGER_VERSION=${AGLEDGER_VERSION}
POSTGRES_USER=agledger
POSTGRES_DB=agledger
HOST=0.0.0.0
PORT=3000
NODE_ENV=production
LOG_LEVEL=info
ALLOW_DB_WITHOUT_SSL=true
REGISTRATION_ENABLED=false
ENVEOF
  fi

  POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
  sedi "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" "$ENV_FILE"
  info "Generated POSTGRES_PASSWORD"

  info "Generating API_KEY_SECRET..."
  API_KEY_SECRET=$(openssl rand -hex 32) \
    || fatal "Failed to generate API_KEY_SECRET"
  sedi "s|API_KEY_SECRET=.*|API_KEY_SECRET=${API_KEY_SECRET}|" "$ENV_FILE"
  info "Generated API_KEY_SECRET"

  info "Generating VAULT_SIGNING_KEY..."
  VAULT_SIGNING_KEY_OUTPUT=$(docker run --rm "${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}" \
    dist/scripts/generate-signing-key.js 2>/dev/null) \
    || fatal "Failed to generate VAULT_SIGNING_KEY. Is the image available? Try: docker pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}"
  VAULT_SIGNING_KEY=$(echo "$VAULT_SIGNING_KEY_OUTPUT" | grep -oP '(?<=VAULT_SIGNING_KEY=)\S+' | head -1 || true)
  if [[ -z "$VAULT_SIGNING_KEY" ]]; then
    fatal "Could not parse VAULT_SIGNING_KEY from output"
  fi
  sedi "s|VAULT_SIGNING_KEY=.*|VAULT_SIGNING_KEY=${VAULT_SIGNING_KEY}|" "$ENV_FILE"
  info "Generated VAULT_SIGNING_KEY"

  # Enable non-SSL for bundled Postgres (no TLS configured by default)
  sedi "s|.*ALLOW_DB_WITHOUT_SSL=.*|ALLOW_DB_WITHOUT_SSL=true|" "$ENV_FILE"

  # Keep REGISTRATION_ENABLED=false by default (matches .env.example posture).
  # Admin uses the printed platform API key to create the first enterprise via
  # POST /v1/admin/enterprises. Customers who explicitly want open self-service
  # registration can flip this to true in .env after install. (F-408)

  # Persist COMPOSE_FILE so `docker compose <cmd>` run manually from compose/
  # picks up all the overlays this installer selected (prod + optional bundled
  # postgres). Without this, manual commands drop to bare docker-compose.yml
  # and e.g. the postgres container stops reacting to `restart`. (F-410)
  OVERLAY_LIST="docker-compose.yml"
  if [[ "${USES_BUNDLED_PG:-true}" == "true" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.postgres.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.postgres.yml"
  fi
  if [[ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.prod.yml"
  fi
  upsert_env_var COMPOSE_FILE "${OVERLAY_LIST}" "$ENV_FILE"
  info "Persisted COMPOSE_FILE=${OVERLAY_LIST}"

  upsert_env_var AGLEDGER_VERSION "${AGLEDGER_VERSION}" "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  info "Updated ${ENV_FILE}"
fi

# --- Detect Database Mode ---

# Source .env to pick up DATABASE_URL if customer pre-configured it
# shellcheck disable=SC1090
source "$ENV_FILE"

detect_db_mode
if [[ "${EXTERNAL_DB_FLAG}" == "true" ]]; then
  USES_BUNDLED_PG=false
fi

if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  # Set bundled PG flag in .env so the startup banner shows correctly
  if ! grep -q 'AGLEDGER_PG_BUNDLED=' "$ENV_FILE"; then
    echo "AGLEDGER_PG_BUNDLED=true" >> "$ENV_FILE"
  fi
fi

if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  if [[ -z "${DATABASE_URL:-}" ]]; then
    fatal "External database mode requires DATABASE_URL in .env (or use --version without --external-db for bundled postgres)"
  fi
  info "External database detected: skipping bundled PostgreSQL"
  info "DATABASE_URL points to: $(echo "${DATABASE_URL}" | sed -E 's|://[^@]*@|://***@|')"

  # --- Validate external database ---
  step "Validating external database"

  # Test basic connectivity
  info "Testing database connectivity..."
  DB_TEST_OUTPUT=$(docker run --rm \
    -e DATABASE_URL="${DATABASE_URL}" \
    -e ALLOW_DB_WITHOUT_SSL="${ALLOW_DB_WITHOUT_SSL:-false}" \
    "${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}" \
    /nodejs/bin/node -e "
      const pg = require('pg');
      const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
      pool.query('SELECT version() AS v')
        .then(r => { console.log('PG_VERSION=' + r.rows[0].v); pool.end(); })
        .catch(e => { console.error('DB_ERROR=' + e.message); process.exit(1); });
    " 2>&1) || {
    error "Cannot connect to external database."
    error "Output: ${DB_TEST_OUTPUT}"
    fatal "Fix DATABASE_URL in .env and re-run."
  }
  PG_VERSION_STR=$(echo "$DB_TEST_OUTPUT" | grep '^PG_VERSION=' | head -1 | cut -d= -f2- || true)
  if [[ -n "$PG_VERSION_STR" ]]; then
    info "Connected: ${PG_VERSION_STR}"
    # Check PG version >= 17
    PG_MAJOR=$(echo "$PG_VERSION_STR" | grep -oP 'PostgreSQL \K\d+' || echo "0")
    if [[ "$PG_MAJOR" -lt 17 ]]; then
      warn "PostgreSQL ${PG_MAJOR} detected. PostgreSQL 17+ recommended."
    fi
  fi

  # Test LISTEN/NOTIFY (pg-boss requirement)
  info "Testing LISTEN/NOTIFY support..."
  LISTEN_OUTPUT=$(docker run --rm \
    -e DATABASE_URL="${DATABASE_URL}" \
    -e ALLOW_DB_WITHOUT_SSL="${ALLOW_DB_WITHOUT_SSL:-false}" \
    "${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}" \
    /nodejs/bin/node -e "
      const pg = require('pg');
      const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
      client.connect()
        .then(() => client.query('LISTEN agledger_test'))
        .then(() => { console.log('LISTEN_OK'); return client.end(); })
        .catch(e => { console.error('LISTEN_ERROR=' + e.message); process.exit(1); });
    " 2>&1) || true
  if echo "$LISTEN_OUTPUT" | grep -q 'LISTEN_OK'; then
    info "LISTEN/NOTIFY: working"
  else
    warn "LISTEN/NOTIFY test failed. If using a connection pooler (RDS Proxy, PgBouncer),"
    warn "switch to a direct connection. pg-boss requires LISTEN/NOTIFY."
  fi
fi

# --- Pull Images ---

step "Pulling images"

build_compose_cmd
"${COMPOSE[@]}" pull
info "All images pulled"

# --- Start Data Stores ---

if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  step "Starting data stores"

  "${COMPOSE[@]}" up -d postgres
  info "Postgres container started"

  # Wait for healthchecks
  info "Waiting for healthchecks (timeout: ${HEALTHCHECK_TIMEOUT}s)..."
  ELAPSED=0
  while [[ $ELAPSED -lt $HEALTHCHECK_TIMEOUT ]]; do
    PG_HEALTHY=$("${COMPOSE[@]}" ps postgres --format json 2>/dev/null | grep -c '"healthy"' || true)

    if [[ "$PG_HEALTHY" -ge 1 ]]; then
      info "Postgres: healthy"
      break
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
  done

  if [[ $ELAPSED -ge $HEALTHCHECK_TIMEOUT ]]; then
    fatal "Postgres did not become healthy within ${HEALTHCHECK_TIMEOUT}s. Check: docker compose logs postgres"
  fi
fi

# --- Run Migrations ---

step "Running database migrations"

"${COMPOSE[@]}" run --rm agledger-migrate
info "Migrations complete"

# --- Create Platform API Key (idempotent on reinstall) ---

# If a platform key is already present in .env from a previous install, reuse
# it instead of minting a new one. Creating a second platform owner ID on
# every reinstall produces duplicate keys and banner confusion. (F-392/F-405)
EXISTING_PLATFORM_KEY=""
if grep -qE '^PLATFORM_API_KEY=ach_pla_' "$ENV_FILE" 2>/dev/null; then
  # Use the LAST entry — defensive against older installs that appended
  # multiple lines. We de-dupe below.
  EXISTING_PLATFORM_KEY=$(grep -E '^PLATFORM_API_KEY=ach_pla_' "$ENV_FILE" | tail -1 | cut -d= -f2-)
fi

if [[ -n "$EXISTING_PLATFORM_KEY" ]]; then
  step "Reusing existing platform API key from .env"
  PLATFORM_KEY="$EXISTING_PLATFORM_KEY"
  # De-dupe: rewrite .env so only one PLATFORM_API_KEY= line exists. grep -v
  # exits 1 when nothing matches the inverse pattern; that's not an error
  # here. The size guard below catches the case where the filter genuinely
  # produced an empty file (which would wipe a real .env).
  TMP_ENV=$(mktemp)
  grep -vE '^PLATFORM_API_KEY=|^# --- Platform API Key' "$ENV_FILE" > "$TMP_ENV" || true
  if [[ ! -s "$TMP_ENV" ]] && [[ -s "$ENV_FILE" ]]; then
    rm -f "$TMP_ENV"
    fatal "Refusing to truncate .env (filter produced empty output despite non-empty source)"
  fi
  {
    echo ""
    echo "# --- Platform API Key (from initial install) ---"
    echo "PLATFORM_API_KEY=${PLATFORM_KEY}"
  } >> "$TMP_ENV"
  chmod 600 "$TMP_ENV"
  mv "$TMP_ENV" "$ENV_FILE"
  info "Platform API key retained (install is idempotent)"
else
  step "Creating platform API key"

  # docker compose ps --format json reports Networks as a comma-separated STRING,
  # not an object — so `keys[0]` fails. Detect via the running postgres container's
  # actual network attachments, falling back to parsing the Networks string, then
  # finally to the install-repo layout default.
  COMPOSE_NETWORK=""
  POSTGRES_CID=$("${COMPOSE[@]}" ps -q postgres 2>/dev/null | head -1 || true)
  if [[ -n "$POSTGRES_CID" ]]; then
    COMPOSE_NETWORK=$(docker inspect "$POSTGRES_CID" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$COMPOSE_NETWORK" ]]; then
    COMPOSE_NETWORK=$("${COMPOSE[@]}" ps --format json 2>/dev/null | head -1 | jq -r '.Networks // "" | split(",")[0] // ""' 2>/dev/null || true)
  fi
  if [[ -z "$COMPOSE_NETWORK" ]]; then
    # Install-repo layout: compose files live in compose/ subdir, project name "compose"
    COMPOSE_NETWORK="compose_default"
  fi
  info "Using compose network: ${COMPOSE_NETWORK}"

  # Build DATABASE_URL via a temp env file to avoid exposing password in ps output
  INIT_ENV=$(mktemp)
  cat "$ENV_FILE" > "$INIT_ENV"

  # If using bundled postgres and no DATABASE_URL is set, construct one
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && ! grep -q '^DATABASE_URL=' "$INIT_ENV"; then
    PG_USER=$(grep POSTGRES_USER "$ENV_FILE" | head -1 | cut -d= -f2-)
    PG_PASS=$(grep POSTGRES_PASSWORD "$ENV_FILE" | head -1 | cut -d= -f2-)
    PG_DB=$(grep POSTGRES_DB "$ENV_FILE" | head -1 | cut -d= -f2-)
    echo "DATABASE_URL=postgresql://${PG_USER}:${PG_PASS}@postgres:5432/${PG_DB}" >> "$INIT_ENV"
  fi
  chmod 600 "$INIT_ENV"

  INIT_OUTPUT=$(docker run --rm \
    --env-file "$INIT_ENV" \
    --network "${COMPOSE_NETWORK}" \
    "${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}" \
    dist/scripts/init.js --non-interactive 2>&1) || true
  rm -f "$INIT_ENV"

  # Extract the platform key from output (look for ach_pla_ prefix)
  PLATFORM_KEY=$(echo "$INIT_OUTPUT" | grep -oP 'ach_pla_[A-Za-z0-9_-]+' | head -1 || true)

  if [[ -n "$PLATFORM_KEY" ]]; then
    info "Platform API key created"
    # Save to .env so upgrade/smoke scripts can use it (file is already chmod 600)
    {
      echo ""
      echo "# --- Platform API Key (generated at install) ---"
      echo "PLATFORM_API_KEY=${PLATFORM_KEY}"
    } >> "$ENV_FILE"
    info "Platform API key saved to .env"
  else
    warn "Could not extract platform API key from init output."
    warn "You can regenerate it later."
    echo ""
    echo "--- init output ---"
    echo "$INIT_OUTPUT" | grep -v -iE '(password|secret|key_secret)' || true
    echo "--- end output ---"
  fi
fi

# --- Start All Services ---

step "Starting all services"

"${COMPOSE[@]}" up -d --no-recreate agledger-api --wait \
  || fatal "Failed to start API. Check: docker compose logs agledger-api"

if [[ "$WITH_MONITORING" == true ]]; then
  "${COMPOSE[@]}" --profile monitoring up -d --no-recreate --wait
else
  "${COMPOSE[@]}" up -d --no-recreate --wait
fi
info "All services started"

# --- Preflight Check ---

step "Running preflight checks"

sleep 5
"${COMPOSE[@]}" exec agledger-api /nodejs/bin/node dist/scripts/preflight.js 2>&1 || {
  warn "Preflight checks returned warnings (non-fatal). Review output above."
}

# --- Summary ---

API_PORT=3001
API_URL="http://localhost:${API_PORT}"

echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN}  AGLedger — Installation Complete${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo -e "  ${BOLD}Version:${NC}       ${AGLEDGER_VERSION}"
echo -e "  ${BOLD}API URL:${NC}       ${API_URL}"
echo -e "  ${BOLD}Health:${NC}        ${API_URL}/health"
echo -e "  ${BOLD}Conformance:${NC}   ${API_URL}/conformance"
echo -e "  ${BOLD}API Docs:${NC}      ${API_URL}/docs"
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  echo -e "  ${BOLD}Database:${NC}      External ($(echo "${DATABASE_URL}" | sed -E 's|://[^@]*@|://***@|' | cut -d'?' -f1))"
else
  echo -e "  ${BOLD}Database:${NC}      Bundled PostgreSQL"
fi
echo ""

if [[ -n "${PLATFORM_KEY:-}" ]]; then
  echo -e "  ${BOLD}${RED}Platform API Key (SAVE THIS — shown only once):${NC}"
  echo ""
  echo -e "    ${YELLOW}${PLATFORM_KEY}${NC}"
  echo ""
  echo -e "  This key has full admin access. Store it securely."
fi

if [[ "$WITH_MONITORING" == true ]]; then
  echo ""
  echo -e "  ${BOLD}Monitoring:${NC}"
  echo -e "    Jaeger UI:     http://localhost:16686"
  echo -e "    Prometheus:    http://localhost:9090"
  echo -e "    Grafana:       http://localhost:3003 (admin / admin)"
fi

echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    Learn what AGLedger does:   https://agledger.ai/how-it-works"
echo -e "    Self-hosted install guide:  https://agledger.ai/docs/guides/self-hosted/install"
echo -e "    API reference (Swagger):    ${API_URL}/docs"
echo -e "    Container status:           docker compose ps"

# Telemetry notice for Developer Edition installs
if [[ "${USES_BUNDLED_PG}" == "true" ]] || [[ -z "${AGLEDGER_LICENSE_KEY:-}" ]]; then
  echo ""
  echo -e "  ${BOLD}Telemetry:${NC}"
  echo -e "    Anonymous usage telemetry is enabled (heartbeat every 48h)."
  echo -e "    Disable: set AGLEDGER_TELEMETRY=false in .env"
  echo -e "    Or apply an Enterprise license to auto-disable."
fi

echo ""
echo -e "${GREEN}=============================================================================${NC}"
