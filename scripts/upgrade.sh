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
    --skip-verify)
      export AGLEDGER_SKIP_VERIFY=true
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
      echo "  --skip-verify        Skip image signature verification (dev/local ONLY)"
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

# Two sources, and neither is `resolve_version`. That helper answers "which
# version should we install", falling through to the repo's package.json and
# then to "latest". In a source checkout it returns the version being released,
# which is the TARGET; reported as the current version it made the equality
# check below true, and the upgrade exited "Nothing to do" without upgrading
# anything. It also never returns empty, so the docker probe underneath it was
# unreachable (#1170).
#
# What is running is either written down (.env, set by install.sh and by this
# script) or readable off the running container. Nothing else is evidence.
CURRENT_VERSION="$(get_env_value AGLEDGER_VERSION "$ENV_FILE")"

# The tag is whatever follows the last colon of the image ref; `${ref##*:}` says
# that directly and, unlike `grep -oP`, works on macOS, whose BSD grep has no -P.
#
# Shape-checked, because install.sh writes AGLEDGER_IMAGE_PIN on every verified
# install and compose prefers it, so the ref this reads is usually
# `agledger/agledger@sha256:<64 hex>`, which has no tag at all. The same `##*:`
# happily returns the digest hex, and a 64-character hash reported as "current
# version" would be printed at the confirmation prompt and written into
# backup/.pre-upgrade-version, the one file that says what to roll back to.
if [[ -z "$CURRENT_VERSION" ]]; then
  RUNNING_IMAGE_REF=$(docker inspect --format '{{.Config.Image}}' \
    "$(docker compose -f "${COMPOSE_DIR}/docker-compose.yml" ps -q agledger-api 2>/dev/null | head -1)" 2>/dev/null || true)
  RUNNING_TAG="${RUNNING_IMAGE_REF##*:}"
  if [[ "$RUNNING_TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    CURRENT_VERSION="$RUNNING_TAG"
  fi
fi

# Kept out of the equality check below: "unknown" is never a target version, so
# an upgrade whose starting point cannot be established runs rather than skips.
CURRENT_VERSION="${CURRENT_VERSION:-unknown}"

info "Current version: ${CURRENT_VERSION}"
info "Target version:  ${TARGET_VERSION}"

# --- Detect removed env vars (v0.15.0+) ---

# POSIX BRE intervals (`\{0,1\}`, `[[:space:]][[:space:]]*`), not the GNU
# extensions `\?` and `\+`: BSD sed and BSD grep read those as a literal `?`
# and `+`, so on macOS both the detection and the rewrite below silently match
# nothing, so the line would survive an upgrade that reported success.
#
# The Server ignores the variable rather than rejecting it: src/config.ts reads
# AGLEDGER_LICENSE / AGLEDGER_LICENSE_KEY / AGLEDGER_LICENSE_KEY_FILE and
# nothing else. Commenting it out keeps .env honest about what is actually
# live; it is tidying, not a boot prerequisite.
if grep -q '^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}AGLEDGER_LICENSE_MODE[[:space:]]*=' "$ENV_FILE" 2>/dev/null; then
  warn "AGLEDGER_LICENSE_MODE was removed in v0.15.0 and is ignored by the Server."
  warn "Commenting it out in ${ENV_FILE}."
  sedi 's/^\([[:space:]]*\)\(export[[:space:]][[:space:]]*\)\{0,1\}\(AGLEDGER_LICENSE_MODE[[:space:]]*=\)/#REMOVED_v0.15# \1\2\3/' "$ENV_FILE"
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

# --- Federation Identity ---
# #1193: the same gap install.sh now closes, reached from the other direction.
# An install stood up before that fix has no AGLEDGER_INSTANCE_ID, so its
# operator is told the Server's id is the literal "default" and the peer's
# handshake refuses it. `federation_hub_id_action` will not touch a Server that
# already has a usable id, so an upgrade can never move an identity peers have
# stored: it only fills in the absent case.
if [[ "$(federation_hub_id_action "$ENV_FILE")" == "generate" ]]; then
  if HUB_ID_VALUE=$(generate_uuid); then
    upsert_env_var AGLEDGER_INSTANCE_ID "${HUB_ID_VALUE}" "$ENV_FILE"
    info "Generated AGLEDGER_INSTANCE_ID (this Server's federation identity; it had none)"
  else
    warn "Could not generate AGLEDGER_INSTANCE_ID. Federation stays unavailable until one is set;"
    warn "GET /federation/v1/admin/instance names the variable and how to generate a value."
  fi
fi

# --- Monitoring Profile ---
# #1180: an install stood up with --with-monitoring before COMPOSE_PROFILES was
# persisted has monitoring containers running and nothing in .env that selects
# them. Every compose command here, including the `up -d` below, would then skip
# the profile: the containers keep running on the OLD image with the OLD port
# bindings while the upgrade reports success, and the release notes describe a
# hardening the machine never received. Repair the .env before anything else
# reads it, so the profile also sticks for the operator's own later commands.
MONITORING_ACTIVE=false
if monitoring_containers_running; then
  MONITORING_ACTIVE=true
  if [[ "$(ensure_monitoring_profile "$ENV_FILE")" == "added" ]]; then
    info "Monitoring containers are running but COMPOSE_PROFILES did not select them."
    info "  Added COMPOSE_PROFILES=monitoring to .env so this upgrade includes them."
  fi
fi

# --- Config Gate ---
#
# `missing_prod_config` names every production prerequisite the Server
# fail-fasts on. install.sh runs it and REFUSES; here it warns, and the
# difference is deliberate.
#
# The function reads .env and nothing else. On a first install that is the whole
# truth. On an upgrade there is a Server already running, which is standing
# evidence the configuration works, and an operator may be supplying these from
# an exported environment or a secrets manager rather than the file. Refusing
# would block a working customer's upgrade over a variable that is in fact set.
#
# Warning still buys the whole point of #1163: if the new image does fail to
# boot, the operator already has the variable name in front of them instead of
# "container is unhealthy". CONFIG_GAPS is re-reported on that failure below.
CONFIG_GAPS=()
while IFS= read -r gap_line; do
  CONFIG_GAPS+=("$gap_line")
done < <(missing_prod_config "$ENV_FILE")

if [[ ${#CONFIG_GAPS[@]} -gt 0 ]]; then
  warn "${ENV_FILE} does not set every production prerequisite:"
  for gap in "${CONFIG_GAPS[@]}"; do
    warn "  ${gap}"
  done
  warn "If they reach the container another way (exported env, secrets manager), this is fine."
  warn "If they do not, ${TARGET_VERSION} will refuse to boot and this upgrade will stop at the restart."
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

# --- Verify + Pull New Image ---
# Verify the new image's signature BEFORE migrations run against it
# (cross-repo #667). Pins the upgraded stack to the verified digest.

verify_image "$AGLEDGER_IMAGE" "$TARGET_VERSION" \
  || fatal "Image signature verification failed — aborting upgrade before running an unverified image."
if [[ -n "${RESOLVED_DIGEST:-}" ]]; then
  upsert_env_var AGLEDGER_IMAGE_PIN "${AGLEDGER_IMAGE}@${RESOLVED_DIGEST}" "${COMPOSE_DIR}/.env"
  info "Pinned upgrade to verified digest: ${RESOLVED_DIGEST}"
else
  # No digest resolved (verification skipped / cosign absent). Drop any stale pin
  # from a prior version so migrate + restart run the NEW target, not the old digest.
  sedi '/^AGLEDGER_IMAGE_PIN=/d' "${COMPOSE_DIR}/.env"
fi

# --- Stop Worker ---

step "Stopping worker (prevent job processing during migration)"

build_compose_cmd
"${COMPOSE[@]}" stop agledger-worker 2>/dev/null || true
info "Worker stopped"

# --- Run Migrations ---

step "Running database migrations with new image"

# Postgres's own healthcheck runs inside its container, so it passes while
# sibling-container traffic on the compose bridge is being dropped by stale
# Docker iptables state. install.sh probes for exactly this before its migrate
# and upgrade.sh did not, though it runs the same `compose run agledger-migrate`
# a line later: the customer got a ~55s TCP timeout and a Node stack trace
# instead of the named recovery. The window is if anything wider here, because
# an upgrade happens on a host that has been running (and restarting Docker)
# since the install that did check.
verify_sibling_reachability

AGLEDGER_VERSION="${TARGET_VERSION}" "${COMPOSE[@]}" run --rm agledger-migrate
info "Migrations complete"

# --- Update Version in .env ---

step "Updating configuration"

upsert_env_var AGLEDGER_VERSION "${TARGET_VERSION}" "$ENV_FILE"
info "Updated AGLEDGER_VERSION=${TARGET_VERSION} in .env"

# --- Restart All Services ---

step "Restarting all services"

# --wait fails the upgrade if the new image crashloops at boot (e.g. a
# missing runtime asset like F-447). Without it, `up -d` returns as soon as
# the container is created, the preflight loop below logs a soft WARN, and
# the script exits 0 — handing the customer a broken upgrade with no
# visible signal anything went wrong.
if ! "${COMPOSE[@]}" up -d --wait; then
  # A config fail-fast is the likeliest cause and the one the generic message
  # hid: the Server names the variable and exits at import, compose reports
  # "unhealthy", and the operator was sent to read container logs to find out
  # which one. If the gate above found gaps, they are almost certainly it.
  if [[ ${#CONFIG_GAPS[@]} -gt 0 ]]; then
    error "${TARGET_VERSION} did not boot, and ${ENV_FILE} is missing production prerequisites:"
    for gap in "${CONFIG_GAPS[@]}"; do
      error "  ${gap}"
    done
    error "Set them in ${ENV_FILE} and re-run this script. Your previous version is still installed."
  fi
  fatal "Services failed to become healthy after upgrade. Check: docker compose logs agledger-api"
fi
info "All services restarted"

# --- Grafana Credential State ---
# #1180: the installer generates GRAFANA_ADMIN_PASSWORD on a fresh monitoring
# install, and warns when a Grafana volume already exists because the password
# is applied only when the admin user is created and ignored on every later
# boot. Neither ran on the upgrade path, so an install that predates the change
# came out the far side still answering to admin/admin with nothing anywhere in
# the output saying so. The generate branch cannot apply here for the same
# reason it does not apply in the installer: the volume already pinned it.
if [[ "$MONITORING_ACTIVE" == true ]] \
  && [[ "$(grafana_password_action "$ENV_FILE")" == "stale" ]]; then
  echo ""
  warn "Grafana is running from an existing volume, so its admin password is whatever it was first started with."
  warn "  Releases before 1.4.0 defaulted it to 'admin', which is very likely what it still is. To set a new one:"
  warn "    docker compose exec grafana grafana cli admin reset-admin-password <new-password>"
  warn "  then record it as GRAFANA_ADMIN_PASSWORD in ${ENV_FILE}."
  warn "  The port bindings moved to loopback in this upgrade, so it is no longer reachable off this host."
fi

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

# POSIX sed rather than two chained `grep -oP`: BSD grep (macOS) has no -P, and
# sed prints nothing instead of failing when /health returned {}, so the
# fallback moves into the expansion.
HEALTH_VERSION=$(echo "$HEALTH_RESPONSE" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
HEALTH_VERSION="${HEALTH_VERSION:-unknown}"
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
echo -e "    curl -s http://localhost:$(resolve_host_port AGLEDGER_HOST_PORT 3001)/health | jq ."
echo -e "    docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
echo ""
echo -e "${GREEN}=============================================================================${NC}"
