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

MIGRATE_LOG=""

# Set by an exit path that has already told the operator, in specific terms,
# what went wrong and what to run. The generic two-liner below would land under
# that and contradict it: the keyless exit says the stack is up and names one
# command, this says the installation failed and names a different one.
EXIT_ALREADY_EXPLAINED=false

cleanup() {
  # Capture first: anything run before this read would overwrite $?.
  local status=$?
  [[ -n "$MIGRATE_LOG" ]] && rm -f "$MIGRATE_LOG"
  if [[ $status -ne 0 ]] && [[ "$EXIT_ALREADY_EXPLAINED" != true ]]; then
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
FIPS_FLAG=false
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
    --fips)
      FIPS_FLAG=true
      shift
      ;;
    --skip-verify)
      export AGLEDGER_SKIP_VERIFY=true
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
      echo "  --fips               Run containers with the OpenSSL FIPS provider active."
      echo "                       Implies ES256 signing: the provider cannot compute Ed25519."
      echo "  --skip-verify        Skip image signature verification (dev/local ONLY — never production)"
      echo "  -h, --help           Show this help message"
      exit 0
      ;;
    *)
      fatal "Unknown argument: $1 (use --help for usage)"
      ;;
  esac
done

# --- Signing Algorithm ---
# AGLEDGER_SIGNING_ALGORITHM: ed25519 (default) or es256. es256 is for FIPS-mode
# hosts, whose providers cannot compute Ed25519.
#
# Resolved here, with the rest of the argument handling, so a contradictory or
# misspelled request is rejected before the script probes ports, contacts a
# registry, or writes anything. --fips implies es256 rather than silently
# pairing the FIPS provider with a key it cannot sign with; an explicit
# contradiction is refused, not quietly overridden.
if [[ "$FIPS_FLAG" == true ]]; then
  if [[ -n "${AGLEDGER_SIGNING_ALGORITHM:-}" && "${AGLEDGER_SIGNING_ALGORITHM}" != "es256" ]]; then
    fatal "--fips requires ES256 signing, but AGLEDGER_SIGNING_ALGORITHM=${AGLEDGER_SIGNING_ALGORITHM} was requested. The FIPS provider carries no EdDSA, so an Ed25519 key cannot sign under it. Drop one of the two."
  fi
  AGLEDGER_SIGNING_ALGORITHM=es256
fi
SIGNING_ALGORITHM="${AGLEDGER_SIGNING_ALGORITHM:-ed25519}"
case "$SIGNING_ALGORITHM" in
  ed25519|es256) ;;
  *) fatal "AGLEDGER_SIGNING_ALGORITHM must be ed25519 or es256, got: ${SIGNING_ALGORITHM}" ;;
esac

# Override image if --image was provided. A tag in --image (repo:tag) is split
# off here: image refs are later composed as ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION},
# so a tagged --image would otherwise compose an invalid `repo:tag:version`. A ':'
# only counts as a tag when it's in the final path segment (after the last '/'),
# so a registry port (e.g. localhost:5000/agledger) isn't mistaken for one; a
# digest pin (...@sha256:...) is left untouched.
if [[ -n "$CUSTOM_IMAGE" ]]; then
  image_last_segment="${CUSTOM_IMAGE##*/}"
  if [[ "$image_last_segment" == *:* && "$image_last_segment" != *@* ]]; then
    image_tag="${CUSTOM_IMAGE##*:}"
    CUSTOM_IMAGE="${CUSTOM_IMAGE%:*}"
    if [[ -z "$REQUESTED_VERSION" ]]; then
      REQUESTED_VERSION="$image_tag"
    elif [[ "$REQUESTED_VERSION" != "$image_tag" ]]; then
      fatal "--image tag ':${image_tag}' conflicts with --version '${REQUESTED_VERSION}'. Pass a tagless --image (e.g. registry/agledger) plus --version, or make them match."
    fi
  fi
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

# curl (used for Docker Hub tag lookup)
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

# --- Host Ports ---
# Resolved and checked before anything is pulled or written, because a
# collision surfaces from the Docker daemon as a bare "Bind for 127.0.0.1:5432
# failed: port is already allocated" halfway through `compose up`, with the
# stack half-started and nothing saying which knob moves it.
#
# COMPOSE_PROJECT_NAME gives a second install its own containers, network and
# volumes, but host ports are global, so side-by-side installs need these too.

step "Checking host ports"

API_HOST_PORT="$(resolve_host_port AGLEDGER_HOST_PORT 3001)"
PG_HOST_PORT="$(resolve_host_port POSTGRES_HOST_PORT 5432)"
JAEGER_HOST_PORT="$(resolve_host_port JAEGER_UI_HOST_PORT 16686)"
PROM_HOST_PORT="$(resolve_host_port PROMETHEUS_HOST_PORT 9090)"
GRAF_HOST_PORT="$(resolve_host_port GRAFANA_HOST_PORT 3003)"
OTLP_GRPC_PORT="$(resolve_host_port OTLP_GRPC_HOST_PORT 4317)"
OTLP_HTTP_PORT="$(resolve_host_port OTLP_HTTP_HOST_PORT 4318)"
OTEL_METRICS_PORT="$(resolve_host_port OTEL_METRICS_HOST_PORT 8889)"

# Ports this run will publish, as "VAR=port=label" so a collision can name the
# variable that moves it. Postgres is only published with the bundled overlay,
# and the monitoring ports only under --with-monitoring. Checking a port the
# stack never binds would refuse an install for no reason, so the bundled-PG
# question is answered the same way it is later: the flag, or a DATABASE_URL
# that points somewhere other than the bundled host. .env has not been sourced
# at this point, so read it directly.
PORTS_TO_PUBLISH=("AGLEDGER_HOST_PORT=${API_HOST_PORT}=API")
PUBLISHES_BUNDLED_PG=false
if [[ "${EXTERNAL_DB_FLAG}" != "true" ]] \
  && database_url_is_bundled "${DATABASE_URL:-$(get_env_value DATABASE_URL "${COMPOSE_DIR}/.env")}"; then
  PUBLISHES_BUNDLED_PG=true
  PORTS_TO_PUBLISH+=("POSTGRES_HOST_PORT=${PG_HOST_PORT}=bundled PostgreSQL")
fi
if [[ "$WITH_MONITORING" == true ]]; then
  PORTS_TO_PUBLISH+=(
    "JAEGER_UI_HOST_PORT=${JAEGER_HOST_PORT}=Jaeger UI"
    "PROMETHEUS_HOST_PORT=${PROM_HOST_PORT}=Prometheus"
    "GRAFANA_HOST_PORT=${GRAF_HOST_PORT}=Grafana"
    "OTLP_GRPC_HOST_PORT=${OTLP_GRPC_PORT}=OTLP gRPC receiver"
    "OTLP_HTTP_HOST_PORT=${OTLP_HTTP_PORT}=OTLP HTTP receiver"
    "OTEL_METRICS_HOST_PORT=${OTEL_METRICS_PORT}=OTel metrics exporter"
  )
fi

PORT_CONFLICTS=()
CONFLICTING_PORTS=()
# Same set as CONFLICTING_PORTS, space-delimited with sentinel spaces, so
# membership is a glob test. Not an associative array: macOS ships bash 3.2.
CONFLICTING_PORTS_LIST=" "
# Newline-separated "port<TAB>VARNAME" seen so far. Deliberately NOT an
# associative array: macOS ships bash 3.2, which has none, and `declare -A`
# there is a syntax error that aborts the whole installer. This file is
# supported on macOS, so it stays bash 3.2 clean.
SEEN_PORTS=""
for spec in "${PORTS_TO_PUBLISH[@]}"; do
  port_var="${spec%%=*}"
  rest="${spec#*=}"
  port="${rest%%=*}"
  label="${rest#*=}"

  valid_host_port "$port" \
    || fatal "${port_var}=${port} is not a valid TCP port (1-65535)."

  # A duplicate inside our own set never reaches the daemon as a useful error:
  # compose reports whichever service loses the race.
  # `|| true` is load-bearing: under `set -euo pipefail` a no-match grep exits 1
  # and pipefail propagates it out of the substitution, killing the script with
  # no message. Not-yet-seen is the normal case for every port.
  prior_var=$(printf '%s' "$SEEN_PORTS" | grep -E "^${port}	" | head -1 | cut -f2 || true)
  if [[ -n "$prior_var" ]]; then
    fatal "${port_var} and ${prior_var} are both set to ${port}. Each published port needs its own value."
  fi
  SEEN_PORTS="${SEEN_PORTS}${port}	${port_var}
"

  if host_port_in_use "$port" && ! host_port_held_by_this_project "$port"; then
    PORT_CONFLICTS+=("${port_var}=${port} (${label})")
    CONFLICTING_PORTS+=("$port")
    CONFLICTING_PORTS_LIST="${CONFLICTING_PORTS_LIST}${port} "
  fi
done

if [[ ${#PORT_CONFLICTS[@]} -gt 0 ]]; then
  error "Another process on this host is already listening on a port this install needs:"
  echo ""
  for c in "${PORT_CONFLICTS[@]}"; do
    error "  ${c}"
  done
  echo ""
  error "Docker would fail this as 'port is already allocated' partway through starting the stack."
  error "Each line names the variable that moves it. Nothing answers on these right now:"
  error "  $(suggest_port_assignments conflicting)./scripts/install.sh"
  # The advice differs by what is holding the port. Most of the time it is
  # something unrelated on the host (a system Postgres on 5432) and moving the
  # port is the whole fix. Only when THIS directory already holds an install
  # does a second stack need a second directory, and saying so unconditionally
  # sent first-time installers off to copy a tree for no reason.
  # Not $ENV_FILE: this check runs before that is assigned.
  if env_file_carries_install_state "${COMPOSE_DIR}/.env"; then
    echo ""
    error "This directory already holds an install, so a second STACK here needs a second"
    error "DIRECTORY: .env is per-directory and holds the ports, signing key, platform key"
    error "and issuer URL. Give it its own copy and its own project name:"
    error "  cp -r $(dirname "${COMPOSE_DIR}") ../agledger-2 && cd ../agledger-2"
    error "  rm -f compose/.env compose/.env.backup-*   # generate fresh secrets, do not inherit"
    # Every published port, not just the colliding ones: in a fresh directory the
    # stack next door holds no ports on THIS project's behalf, so each one this
    # run publishes has to be free on its own.
    error "  COMPOSE_PROJECT_NAME=agledger-2 $(suggest_port_assignments all)./scripts/install.sh"
  else
    error "Installing alongside an AGLedger that lives in another directory needs nothing"
    error "more than the port variables above; run it from THIS directory."
  fi
  error "To find what holds a port:  docker ps   or   sudo lsof -i :${CONFLICTING_PORTS[0]}"
  fatal "Refusing to start a stack that cannot bind its ports."
fi

info "Host ports available: API ${API_HOST_PORT}$([[ "$PUBLISHES_BUNDLED_PG" == "true" ]] && echo ", PostgreSQL ${PG_HOST_PORT}")"

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

# --- Verify Image Signature (before anything executes it) ---
# The image is run below to mint the vault signing key, so it must be proven
# genuine first. Sets RESOLVED_DIGEST; we pin the running stack to that digest.
verify_image "$AGLEDGER_IMAGE" "$AGLEDGER_VERSION" \
  || fatal "Image signature verification failed — aborting before running an unverified image."
AGLEDGER_IMAGE_PIN=""
if [[ -n "${RESOLVED_DIGEST:-}" ]]; then
  AGLEDGER_IMAGE_PIN="${AGLEDGER_IMAGE}@${RESOLVED_DIGEST}"
fi

# --- Environment Configuration ---

step "Configuring environment"

ENV_FILE="${COMPOSE_DIR}/.env"
FRESH_ENV=false
# Whether .env already carries a signing key. Drives both the algorithm
# reconciliation (which has nothing to compare without one) and the per-key
# secret generation below, so it is set before either branch can read it.
HAS_SIGNING_KEY=false

# Refusing to write credentials that cannot authenticate against a Postgres
# data directory some earlier install left behind. Reached from two places: a
# fresh .env (`stale_pgdata_blocks_install`), and a pre-existing .env that
# carries no POSTGRES_PASSWORD, which lands on the same hazard by the other
# door (#1163). Postgres skips initialization on a populated data directory, so
# it keeps the password that volume was built with and every connection using a
# newly generated one fails 28P01. The volume belongs to the compose project,
# not to this checkout, so it survives `docker compose down` and `rm -rf` of
# the directory that created it.
refuse_credentials_against_existing_volume() {
  local PGDATA_VOLUME
  PGDATA_VOLUME="$(compose_pgdata_volume)"
  error "A Postgres data volume already exists on this host: ${PGDATA_VOLUME}"
  echo ""
  error "It holds a database from an earlier install, and it keeps the password that install"
  error "generated. Writing a new .env now would generate a different one, and every connection"
  error "would fail with 'password authentication failed for user \"agledger\"' (SQLSTATE 28P01)."
  echo ""
  error "The volume is named after the compose project (${COMPOSE_DIR##*/}), not after this checkout,"
  error "so it is shared with any other checkout on this host and outlives 'docker compose down'."
  echo ""
  error "Pick one:"
  error "  1. Keep that database. Restore the .env it was installed with into ${ENV_FILE}"
  error "     (POSTGRES_PASSWORD is the field that has to match), then re-run this script."
  error "  2. Discard that database, permanently:"
  error "       docker volume rm ${PGDATA_VOLUME}"
  error "     then re-run this script. Back it up first if you are unsure what is in it:"
  error "       docker run --rm -v ${PGDATA_VOLUME}:/data -v \"\$PWD\":/backup alpine tar czf /backup/pgdata.tgz /data"
  error "  3. Install alongside it, under a separate project name AND its own host ports."
  error "     The project name separates containers, network and volumes; host ports are"
  error "     global to the machine, so they have to move too:"
  error "       COMPOSE_PROJECT_NAME=agledger-2 $(suggest_port_assignments all)./scripts/install.sh"
  fatal "Refusing to generate credentials that cannot authenticate against the existing volume."
}

# A second stack needs a second directory, because .env is the whole state of
# the install and there is one per checkout. Installing under a new project
# name in an installed tree used to succeed and print "Installation Complete",
# leaving the first stack running but orphaned from its own tooling, and the
# second signing its chain under the first stack's key and issuer.
if project_switch_orphans_install "${COMPOSE_PROJECT_NAME:-}"; then
  INSTALLED_PROJECT="$(installed_project_name)"
  error "This directory is already installed as compose project '${INSTALLED_PROJECT}',"
  error "and this run asks for '${COMPOSE_PROJECT_NAME}'."
  echo ""
  error "COMPOSE_PROJECT_NAME would give you separate containers, network and volume,"
  error "but not a separate ${ENV_FILE}: there is one per directory, and it holds the"
  error "ports, the signing key, the platform API key and AGLEDGER_EXTERNAL_URL. Writing"
  error "the new stack's values into it would leave '${INSTALLED_PROJECT}' running and"
  error "unreachable by every later docker compose / upgrade.sh / uninstall.sh run here,"
  error "while the new stack signed its records under the old one's key and issuer."
  echo ""
  error "Install the second one in its own directory instead:"
  # Directory named for the project the operator asked for, so the copy, the cd
  # and COMPOSE_PROJECT_NAME below all read as one stack rather than three names.
  error "  cp -r $(dirname "${COMPOSE_DIR}") ../${COMPOSE_PROJECT_NAME} && cd ../${COMPOSE_PROJECT_NAME}"
  error "  rm -f compose/.env compose/.env.backup-*   # do not carry over the first install's secrets"
  # The port preflight above already cleared these values, so they are the ones
  # the operator asked for and they are free. Echoing them back is the whole
  # point: a recipe carrying different numbers reads as a correction the
  # operator did not make and has no way to check.
  error "  COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME} $(suggest_port_assignments all)./scripts/install.sh"
  echo ""
  error "To re-run against the stack that IS installed here, drop COMPOSE_PROJECT_NAME"
  error "(or set it to '${INSTALLED_PROJECT}'). Ports and --fips still reconcile in place."
  fatal "Refusing to overwrite this directory's install state with a different project."
fi

# Does the install this .env describes still exist on this host?
#
# Read HERE, before anything is written. The issuer reconcile further down needs
# the answer, and by the time it runs COMPOSE_PROJECT_NAME has already been
# rewritten to this run's value, so installed_project_name() no longer names the
# stack the file was describing when the script started.
#
# false means the stack is gone: `uninstall.sh` without `--purge` does
# `down -v --remove-orphans` and keeps .env, which leaves a file that still
# reads like a completed install describing nothing.
#
# Deliberately asks the host only, not .env. Whether .env still carries the
# secrets is a different question, and ANDing it in would let a stack whose
# VAULT_SIGNING_KEY comes from the environment rather than the file read as
# departed while it is live, with records in it.
PRIOR_INSTALL_SURVIVES=false
if installed_project_has_state "$(installed_project_name)"; then
  PRIOR_INSTALL_SURVIVES=true
fi

if [[ -f "$ENV_FILE" ]]; then
  # A .env that EXISTS is not a .env that is CONFIGURED, and the difference is
  # the whole of #1163. `--external-db` documents writing DATABASE_URL into
  # .env before the first run, and the success banner tells operators to set
  # AGLEDGER_EXTERNAL_URL there, so a first install routinely arrives here with
  # a hand-written file holding one line and none of the secrets. Keying
  # generation off the file's existence then produced a .env with no
  # VAULT_SIGNING_KEY and a container that fatally exits on boot, with the
  # installer reporting only "unhealthy". Secrets are ensured per key below;
  # anything already set is still never regenerated.
  HAS_SIGNING_KEY=false
  [[ -n "$(get_env_value VAULT_SIGNING_KEY "$ENV_FILE")" ]] && HAS_SIGNING_KEY=true

  if [[ "$HAS_SIGNING_KEY" == true ]]; then
    warn ".env already exists at ${ENV_FILE}. Keeping it: secrets are not regenerated."
  else
    info ".env already exists at ${ENV_FILE} but carries no signing key."
    info "Keeping what it sets; generating the secrets it is missing."
  fi

  # Skipping secret generation also silently drops anything that only takes
  # effect while secrets are being generated. An operator who exported one of
  # these, then saw "Installation Complete", would otherwise have no signal
  # that the request did not land. The first failed run of an install writes
  # .env, so this is reachable on the very next attempt.
  # The existing key is non-default exactly when the opt-in is recorded next to
  # it, so a request that already matches what is installed stays silent.
  #
  # All of it is scoped to a file that HAS a key: these compare the requested
  # algorithm against the installed one, and with no key installed there is
  # nothing to compare. Unscoped, a hand-written .env reads as "holds an
  # Ed25519 key" and --fips refuses an install that has nothing to refuse.
  if [[ "$HAS_SIGNING_KEY" == true ]]; then
    EXISTING_ALG_OPT_IN=$(get_env_value AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG "$ENV_FILE")
    EXISTING_IS_DEFAULT_ALG=true
    [[ "$EXISTING_ALG_OPT_IN" == "true" ]] && EXISTING_IS_DEFAULT_ALG=false
    REQUESTED_IS_DEFAULT_ALG=true
    [[ "$SIGNING_ALGORITHM" != "ed25519" ]] && REQUESTED_IS_DEFAULT_ALG=false

    # --fips over an existing Ed25519 key is not a warning: the FIPS provider
    # carries no EdDSA, so the Server would come up unable to sign anything. The
    # only correct path is to rotate to an ES256 key first, which preserves the
    # history the existing key signed.
    if [[ "$FIPS_FLAG" == true && "$EXISTING_IS_DEFAULT_ALG" == "true" ]]; then
      error "--fips was requested, but ${ENV_FILE} holds an Ed25519 signing key."
      error "The FIPS provider carries no EdDSA, so this Server would boot unable to sign."
      error "Rotate to ES256 first; entries already written keep verifying under the retired key:"
      error "  1. docker run --rm ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION} dist/scripts/generate-signing-key.js --algorithm es256"
      error "  2. put the new VAULT_SIGNING_KEY and AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true in ${ENV_FILE}"
      error "  3. docker compose up -d --force-recreate   (the restart performs the rotation)"
      error "  4. confirm: curl -s http://localhost:${API_HOST_PORT}/v1/verification-keys"
      error "Then re-run with --fips."
      fatal "Refusing to activate FIPS against a key the provider cannot use."
    fi

    if [[ -n "${AGLEDGER_SIGNING_ALGORITHM:-}" && "$REQUESTED_IS_DEFAULT_ALG" != "$EXISTING_IS_DEFAULT_ALG" ]]; then
      warn "AGLEDGER_SIGNING_ALGORITHM=${AGLEDGER_SIGNING_ALGORITHM} was requested, but the signing key is"
      warn "generated only when one is missing, so this run does NOT change it. The key already in .env stays."
      if [[ "$EXISTING_IS_DEFAULT_ALG" == "true" ]]; then
        warn "That existing key is Ed25519 (no AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG in .env)."
      fi
      warn "To change the algorithm on an install that already has a chain, rotate rather than reinstall:"
      warn "  1. docker run --rm ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION} dist/scripts/generate-signing-key.js --algorithm ${AGLEDGER_SIGNING_ALGORITHM}"
      warn "  2. put the new VAULT_SIGNING_KEY and AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true in ${ENV_FILE}"
      warn "  3. docker compose up -d --force-recreate   (the restart is what rotates: boot reconciles"
      warn "     the key registry to the configured key, retiring the previous one)"
      warn "  4. confirm: curl -s ${API_URL:-http://localhost:${API_HOST_PORT}}/v1/verification-keys"
      warn "Entries already written keep verifying under the retired key; only new entries use the new one."
      warn "For a clean ${AGLEDGER_SIGNING_ALGORITHM} install instead, start from an empty directory."
    fi
  fi

  if pgdata_volume_exists; then
    warn "Its POSTGRES_PASSWORD is the one the existing $(compose_pgdata_volume) volume was initialized with."
    warn "Do NOT delete .env to get a fresh configuration while that volume exists: Postgres keeps the old"
    warn "password on an already-initialized volume, and a regenerated one authenticates against nothing."
  fi
else
  FRESH_ENV=true

  # Fresh credentials plus an existing data volume is the one combination that
  # cannot work. Postgres skips initialization on a populated data directory, so
  # it keeps the password that volume was built with, and every connection using
  # the password we are about to generate fails 28P01. The volume belongs to the
  # compose project, not to this checkout, so it survives `docker compose down`
  # and `rm -rf` of the directory that created it.
  if stale_pgdata_blocks_install "${EXTERNAL_DB_FLAG}"; then
    refuse_credentials_against_existing_volume
  fi
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
ENVEOF
  fi

  # Enable non-SSL for bundled Postgres (no TLS configured by default). Fresh
  # .env only: on a file the operator wrote, DATABASE_URL is theirs and so is
  # the decision to run it without TLS. The preflight below reports it as a
  # missing prerequisite instead of quietly relaxing it for them.
  sedi "s|.*ALLOW_DB_WITHOUT_SSL=.*|ALLOW_DB_WITHOUT_SSL=true|" "$ENV_FILE"

  chmod 600 "$ENV_FILE"
  info "Created ${ENV_FILE}"
fi

# --- Required secrets, ensured per key ---
#
# Runs on BOTH paths. A fresh .env comes from .env.example, whose secret lines
# are empty placeholders, so every key below is generated exactly as it was
# when this block lived in the fresh branch. A pre-existing .env gets only what
# it is actually missing (#1163).

# `pg_password_action` owns this decision rather than an inline `-z`, because
# an absent password still has to be told apart from one that a live data
# volume has already pinned. See lib-compose.sh.
case "$(pg_password_action "$ENV_FILE" "${EXTERNAL_DB_FLAG}")" in
  refuse)
    refuse_credentials_against_existing_volume
    ;;
  generate)
    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    upsert_env_var POSTGRES_PASSWORD "${POSTGRES_PASSWORD}" "$ENV_FILE"
    info "Generated POSTGRES_PASSWORD"
    ;;
esac

# A federation identity, whether or not this install ever federates. It costs
# nothing on a Server that does not (it is an identifier, not a secret, and
# nothing reads it until a peer handshake), and it is the difference between
# federation working and dead-ending: without it the Server reports the literal
# "default" to its operator, and the peer's handshake refuses that value
# because `peerHubId` is declared `format: uuid` (#1193). Generated here rather
# than defaulted in the engine because it has to be STABLE across restarts, and
# .env is what survives a container.
if [[ "$(federation_hub_id_action "$ENV_FILE")" == "generate" ]]; then
  AGLEDGER_INSTANCE_ID_VALUE=$(generate_uuid) \
    || fatal "Failed to generate AGLEDGER_INSTANCE_ID"
  upsert_env_var AGLEDGER_INSTANCE_ID "${AGLEDGER_INSTANCE_ID_VALUE}" "$ENV_FILE"
  info "Generated AGLEDGER_INSTANCE_ID (this Server's federation identity)"
fi

if [[ -z "$(get_env_value API_KEY_SECRET "$ENV_FILE")" ]]; then
  info "Generating API_KEY_SECRET..."
  API_KEY_SECRET=$(openssl rand -hex 32) \
    || fatal "Failed to generate API_KEY_SECRET"
  upsert_env_var API_KEY_SECRET "${API_KEY_SECRET}" "$ENV_FILE"
  info "Generated API_KEY_SECRET"
fi

if [[ "$HAS_SIGNING_KEY" != true ]]; then
  # A non-default algorithm also writes the AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG
  # acknowledgment below (chain consumers need a verifier release that supports it).
  info "Generating VAULT_SIGNING_KEY (${SIGNING_ALGORITHM})..."
  # Run the digest-pinned, signature-verified ref (falls back to tag only when
  # verification was skipped and no digest resolved).
  VAULT_SIGNING_KEY_OUTPUT=$(docker run --rm "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    dist/scripts/generate-signing-key.js --algorithm "$SIGNING_ALGORITHM" 2>/dev/null) \
    || fatal "Failed to generate VAULT_SIGNING_KEY. Is the image available? Try: docker pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}"
  VAULT_SIGNING_KEY=$(echo "$VAULT_SIGNING_KEY_OUTPUT" | parse_signing_key || true)
  if [[ -z "$VAULT_SIGNING_KEY" ]]; then
    fatal "Could not parse VAULT_SIGNING_KEY from output"
  fi
  upsert_env_var VAULT_SIGNING_KEY "${VAULT_SIGNING_KEY}" "$ENV_FILE"
  if [[ "$SIGNING_ALGORITHM" == "es256" ]]; then
    upsert_env_var AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG true "$ENV_FILE"
    info "Wrote AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true (non-default algorithm opt-in)"
  fi
  info "Generated VAULT_SIGNING_KEY"
fi

chmod 600 "$ENV_FILE"

# --- Detect Database Mode ---

# Source .env to pick up DATABASE_URL if customer pre-configured it.
# A fresh .env copied from .env.example carries AGLEDGER_VERSION=latest, so the
# source would otherwise clobber an explicit --version request (or the resolved
# Docker Hub version) and silently install :latest. Preserve the resolved
# version across the source; the reconciliation below writes it back into .env.
RESOLVED_VERSION="$AGLEDGER_VERSION"
# Same hazard for the project name, and worse: compose reads an exported
# COMPOSE_PROJECT_NAME in preference to the one in .env, so letting the source
# overwrite it would create the stack under the requested project while
# recording the old one in .env. Every later bare `docker compose` command
# (and upgrade.sh) would then address the wrong stack.
REQUESTED_PROJECT="${COMPOSE_PROJECT_NAME:-}"
# shellcheck disable=SC1090
source "$ENV_FILE"
AGLEDGER_VERSION="$RESOLVED_VERSION"
if [[ -n "$REQUESTED_PROJECT" ]]; then
  COMPOSE_PROJECT_NAME="$REQUESTED_PROJECT"
fi

# The host ports need the same treatment, and they are the subtlest case: the
# resolution above already gave .env its turn in the precedence chain, but the
# source puts the .env value back into the ENVIRONMENT, where compose reads it
# ahead of .env. Re-assert (and export) what was resolved, or an operator who
# exports a port gets a stack published on the old one while the preflight,
# the summary URL, and the value written back to .env all name the new one.
export AGLEDGER_HOST_PORT="$API_HOST_PORT"
export POSTGRES_HOST_PORT="$PG_HOST_PORT"
export JAEGER_UI_HOST_PORT="$JAEGER_HOST_PORT"
export PROMETHEUS_HOST_PORT="$PROM_HOST_PORT"
export GRAFANA_HOST_PORT="$GRAF_HOST_PORT"
export OTLP_GRPC_HOST_PORT="$OTLP_GRPC_PORT"
export OTLP_HTTP_HOST_PORT="$OTLP_HTTP_PORT"
export OTEL_METRICS_HOST_PORT="$OTEL_METRICS_PORT"

detect_db_mode
if [[ "${EXTERNAL_DB_FLAG}" == "true" ]]; then
  USES_BUNDLED_PG=false
fi

# --fips is sticky: recorded in .env so build_compose_cmd adds the overlay on
# every later run, including upgrade.sh. Without the record, an upgrade would
# recreate the containers without OPENSSL_CONF and the host would quietly stop
# being FIPS, with nothing to notice it (an ES256 key signs either way).
# An install that already carries the flag keeps it; --fips is how it goes on,
# and editing .env is how it comes off.
if [[ "$FIPS_FLAG" == true ]]; then
  AGLEDGER_FIPS=true
fi

# --- Idempotent Environment Reconciliation ---
# Runs on BOTH fresh and existing .env so F-408/F-410/version-tracking fixes
# reach customers who installed at v0.19.16 and re-run install.sh at v0.19.17+.
# Never auto-flips security-sensitive values — only adds missing keys and
# updates version-tracking keys. (F-415)

RECONCILE_CHANGES=()

# F-410: persist COMPOSE_FILE so manual `docker compose` commands from compose/
# pick up all overlays (prod + optional bundled postgres). Without this, manual
# commands drop to bare docker-compose.yml and the postgres container stops
# reacting to `restart`.
OVERLAY_LIST="docker-compose.yml"
if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.postgres.yml" ]]; then
  OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.postgres.yml"
fi
if [[ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]]; then
  OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.prod.yml"
fi
# Last, so its OPENSSL_CONF wins. Same order build_compose_cmd uses, so a
# manual `docker compose` from compose/ and the scripts agree.
if fips_overlay_enabled && [[ -f "${COMPOSE_DIR}/docker-compose.fips.yml" ]]; then
  OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.fips.yml"
fi

EXISTING_COMPOSE_FILE=$(grep -E '^COMPOSE_FILE=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
if [[ "$EXISTING_COMPOSE_FILE" != "$OVERLAY_LIST" ]]; then
  upsert_env_var COMPOSE_FILE "${OVERLAY_LIST}" "$ENV_FILE"
  if [[ -z "$EXISTING_COMPOSE_FILE" ]]; then
    RECONCILE_CHANGES+=("added COMPOSE_FILE=${OVERLAY_LIST}")
  else
    RECONCILE_CHANGES+=("updated COMPOSE_FILE: ${EXISTING_COMPOSE_FILE} → ${OVERLAY_LIST}")
  fi
fi

# Compose reads COMPOSE_PROJECT_NAME from .env, so persisting an explicit one
# keeps later `docker compose` commands and upgrade.sh pointed at the same
# containers and volumes this install created. Unset is the default derivation.
if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
  EXISTING_PROJECT=$(get_env_value COMPOSE_PROJECT_NAME "$ENV_FILE")
  if [[ "$EXISTING_PROJECT" != "$COMPOSE_PROJECT_NAME" ]]; then
    upsert_env_var COMPOSE_PROJECT_NAME "${COMPOSE_PROJECT_NAME}" "$ENV_FILE"
    RECONCILE_CHANGES+=("set COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}")
  fi
fi

# Record the bundled database's identity in .env when it is missing. A fresh
# .env gets both keys from .env.example; a .env the operator wrote by hand has
# neither, and the containers still work because the compose files default them
# to `agledger`. The consumer that does NOT get that substitution is the init
# container two steps down, which the installer runs outside compose with
# `docker run --env-file` and which needs a real user in its connection string.
# An operator's own `psql` reading the file has the same problem.
# (backup.sh / restore.sh / support-bundle.sh are fine either way: they reach
# these values through load_env, which applies the same defaults.)
#
# Deliberately not a RECONCILE_CHANGES entry: the value written is the value
# compose already substituted, so no container's effective configuration
# changed and nothing needs recreating.
if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  for pg_identity_key in POSTGRES_USER POSTGRES_DB; do
    pg_identity_value=$(pg_identity_to_record "$pg_identity_key" "$ENV_FILE" "${!pg_identity_key:-}")
    if [[ -n "$pg_identity_value" ]]; then
      upsert_env_var "$pg_identity_key" "$pg_identity_value" "$ENV_FILE"
      info "Recorded ${pg_identity_key}=${pg_identity_value} (the value the bundled database was created with)"
    fi
  done
fi

# Keep .env agreeing with the port this run actually published. The decision of
# whether a write is needed lives in host_port_needs_persisting (lib-compose.sh),
# where it is directly testable; this only writes and logs.
persist_host_port() {
  local key="$1" value="$2" default="$3" existing
  host_port_needs_persisting "$key" "$value" "$default" "$ENV_FILE" || return 0
  existing=$(get_env_value "$key" "$ENV_FILE")
  upsert_env_var "$key" "$value" "$ENV_FILE"
  if [[ "$value" == "$default" ]]; then
    RECONCILE_CHANGES+=("set ${key}=${value} (back to the stock port; .env still said ${existing})")
  else
    RECONCILE_CHANGES+=("set ${key}=${value}")
  fi
}
if [[ "${AGLEDGER_FIPS:-}" == "true" ]] && [[ "$(get_env_value AGLEDGER_FIPS "$ENV_FILE")" != "true" ]]; then
  upsert_env_var AGLEDGER_FIPS true "$ENV_FILE"
  RECONCILE_CHANGES+=("set AGLEDGER_FIPS=true (containers run with the OpenSSL FIPS provider active)")
fi

persist_host_port AGLEDGER_HOST_PORT "$API_HOST_PORT" 3001
persist_host_port POSTGRES_HOST_PORT "$PG_HOST_PORT" 5432
if [[ "$WITH_MONITORING" == true ]]; then
  persist_host_port JAEGER_UI_HOST_PORT "$JAEGER_HOST_PORT" 16686
  persist_host_port PROMETHEUS_HOST_PORT "$PROM_HOST_PORT" 9090
  persist_host_port GRAFANA_HOST_PORT "$GRAF_HOST_PORT" 3003
  persist_host_port OTLP_GRPC_HOST_PORT "$OTLP_GRPC_PORT" 4317
  persist_host_port OTLP_HTTP_HOST_PORT "$OTLP_HTTP_PORT" 4318
  persist_host_port OTEL_METRICS_HOST_PORT "$OTEL_METRICS_PORT" 8889
fi

# AGLEDGER_EXTERNAL_URL is the issuer signed into every record, so it must name
# the port this install actually serves. Every other port variable next to it
# reconciles; an issuer that does not is the one value the summary calls
# unfixable-after-the-fact left pointing at a port nothing answers on.
#
# Three cases, and the difference is whether records exist that the current
# issuer already signed:
#
#   fresh .env            -> rewrite. Nothing has been written under it.
#   no surviving install  -> rewrite. `uninstall.sh` keeps .env but does
#                            `down -v`, so on bundled Postgres the chain that
#                            issuer signed went with the volume. Reinstalling
#                            under new ports here left the Server signing under
#                            a dead issuer, silently (#1128).
#   live install          -> warn only. Records exist, and the URL may be a real
#                            domain behind a proxy where the host port is
#                            irrelevant anyway.
#
# The no-surviving-install case is gated on bundled Postgres on purpose. With an
# external database `down -v` destroys nothing, so the records the old issuer
# signed are still in that database and the warn is still the right answer.
#
# Gated on the URL disagreeing with the port, NOT on the port being
# non-default: an issuer left at http://localhost:3011 on an install moved back
# to 3001 is the same defect and needs the same treatment.
ISSUER_DATA_IS_GONE=false
if [[ "$PRIOR_INSTALL_SURVIVES" == false && "$PUBLISHES_BUNDLED_PG" == "true" ]]; then
  ISSUER_DATA_IS_GONE=true
fi
CURRENT_EXTERNAL_URL=$(get_env_value AGLEDGER_EXTERNAL_URL "$ENV_FILE")
case "$CURRENT_EXTERNAL_URL" in
  "")
    # Absent matched no case at all, so a .env the operator wrote by hand got
    # no issuer and the container fatally exited on config load (#1163). A
    # fresh .env never reached this because .env.example ships the localhost
    # form, which the next case reconciles. Same destination, both doors: the
    # loopback issuer the bundled-Postgres default installs under.
    upsert_env_var AGLEDGER_EXTERNAL_URL "http://localhost:${API_HOST_PORT}" "$ENV_FILE"
    RECONCILE_CHANGES+=("added AGLEDGER_EXTERNAL_URL=http://localhost:${API_HOST_PORT} (required in production; it is the issuer signed into every record)")
    if [[ "$FRESH_ENV" != true ]]; then
      info "${ENV_FILE} set no AGLEDGER_EXTERNAL_URL. Production requires one, because it is the"
      info "issuer (\`iss\`) signed into every record, so this run set it to the port this stack"
      info "serves. Change it to your real https:// domain BEFORE notarizing anything you keep."
    fi
    ;;
  http://localhost:*|https://localhost:*|http://127.0.0.1:*|https://127.0.0.1:*)
    if [[ "$CURRENT_EXTERNAL_URL" != *":${API_HOST_PORT}" ]]; then
      if [[ "$FRESH_ENV" == true || "$ISSUER_DATA_IS_GONE" == true ]]; then
        upsert_env_var AGLEDGER_EXTERNAL_URL "http://localhost:${API_HOST_PORT}" "$ENV_FILE"
        RECONCILE_CHANGES+=("set AGLEDGER_EXTERNAL_URL=http://localhost:${API_HOST_PORT} (matches AGLEDGER_HOST_PORT)")
        if [[ "$FRESH_ENV" != true ]]; then
          info "AGLEDGER_EXTERNAL_URL was ${CURRENT_EXTERNAL_URL}, from an install whose database is gone."
          info "Repointed it at the port this stack serves; it is the issuer signed into every record."
        fi
      else
        warn "AGLEDGER_EXTERNAL_URL is ${CURRENT_EXTERNAL_URL} but this install serves port ${API_HOST_PORT}."
        warn "That URL is the issuer signed into every record. Leaving it alone: changing it retroactively"
        warn "would not match records already written. Update it in ${ENV_FILE} if the mismatch is unintended."
      fi
    fi
    ;;
esac

# Track the installed version in .env so upgrade.sh can read it later.
EXISTING_VERSION=$(grep -E '^AGLEDGER_VERSION=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ "$EXISTING_VERSION" != "$AGLEDGER_VERSION" ]]; then
  upsert_env_var AGLEDGER_VERSION "${AGLEDGER_VERSION}" "$ENV_FILE"
  if [[ -z "$EXISTING_VERSION" ]]; then
    RECONCILE_CHANGES+=("added AGLEDGER_VERSION=${AGLEDGER_VERSION}")
  else
    RECONCILE_CHANGES+=("updated AGLEDGER_VERSION: ${EXISTING_VERSION} → ${AGLEDGER_VERSION}")
  fi
fi

# Pin the running stack to the signature-verified digest (cross-repo #667-C1).
# compose images resolve `${AGLEDGER_IMAGE_PIN:-agledger/agledger:${AGLEDGER_VERSION}}`,
# so this makes every container run the exact bytes we just verified — not a
# floating tag that could be repointed after verification.
EXISTING_PIN=$(grep -E '^AGLEDGER_IMAGE_PIN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ -n "${AGLEDGER_IMAGE_PIN:-}" ]] && [[ "$EXISTING_PIN" != "$AGLEDGER_IMAGE_PIN" ]]; then
  upsert_env_var AGLEDGER_IMAGE_PIN "${AGLEDGER_IMAGE_PIN}" "$ENV_FILE"
  RECONCILE_CHANGES+=("pinned image to verified digest: ${AGLEDGER_IMAGE_PIN##*@}")
elif [[ -z "${AGLEDGER_IMAGE_PIN:-}" ]] && [[ -n "$EXISTING_PIN" ]]; then
  # Verification skipped this run but a stale pin lingers — drop it so we don't
  # silently run an old digest against a newly requested version.
  sedi '/^AGLEDGER_IMAGE_PIN=/d' "$ENV_FILE"
fi

# --with-monitoring stands up the collector and Jaeger and points the operator
# at the Jaeger UI, so it has to turn tracing on too. Selecting the compose
# profile alone left the app exporting nothing and the UI permanently empty
# (#1064). Export is OTLP/HTTP, hence the collector's 4318 receiver.
BUNDLED_OTLP_ENDPOINT="http://otel-collector:4318"
OTLP_ENDPOINT_EFFECTIVE=""
GRAFANA_PASSWORD_STATE=keep
if [[ "$WITH_MONITORING" == true ]]; then
  # Grafana is the one bundled service with its own login, and it was the one
  # secret this installer did not generate: compose defaulted it to `admin` and
  # the summary below printed "admin / admin". Generated here like every other
  # credential, but only when Grafana has not already initialized its database:
  # the password is applied when the admin user is created and ignored on every
  # later boot, so on an existing monitoring install writing a new one would
  # record a credential that does not work.
  GRAFANA_PASSWORD_STATE="$(grafana_password_action "$ENV_FILE")"
  if [[ "$GRAFANA_PASSWORD_STATE" == "generate" ]]; then
    GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 32)
    upsert_env_var GRAFANA_ADMIN_PASSWORD "${GRAFANA_ADMIN_PASSWORD}" "$ENV_FILE"
    RECONCILE_CHANGES+=("generated GRAFANA_ADMIN_PASSWORD")
  elif [[ "$GRAFANA_PASSWORD_STATE" == "stale" ]]; then
    warn "Grafana already has a database on this host, so its admin password is whatever it was first started with."
    warn "  Releases before this one defaulted it to 'admin'. To set a new one:"
    warn "    docker compose exec grafana grafana cli admin reset-admin-password <new-password>"
    warn "  then record it as GRAFANA_ADMIN_PASSWORD in ${ENV_FILE}."
  fi

  # Make the profile sticky. Compose reads COMPOSE_PROFILES from .env, so every
  # later `docker compose up -d` (upgrade.sh runs one, with no --profile flag of
  # its own) keeps bringing the collector back up. Without it an upgrade quietly
  # drops the monitoring stack while the app keeps exporting at a host that is
  # no longer there.
  EXISTING_PROFILES=$(get_env_value COMPOSE_PROFILES "$ENV_FILE")
  if [[ ",${EXISTING_PROFILES}," != *",monitoring,"* ]]; then
    NEW_PROFILES="${EXISTING_PROFILES:+${EXISTING_PROFILES},}monitoring"
    upsert_env_var COMPOSE_PROFILES "${NEW_PROFILES}" "$ENV_FILE"
    RECONCILE_CHANGES+=("enabled monitoring profile: COMPOSE_PROFILES=${NEW_PROFILES}")
  fi

  EXISTING_OTLP=$(get_env_value OTEL_EXPORTER_OTLP_ENDPOINT "$ENV_FILE")
  OTLP_ENDPOINT_EFFECTIVE="$EXISTING_OTLP"
  # Repair the gRPC port an earlier .env.example documented; leave any other
  # value alone, since it points at the operator's own collector.
  if [[ -z "$EXISTING_OTLP" ]] || [[ "$EXISTING_OTLP" == "http://otel-collector:4317" ]]; then
    if [[ "$EXISTING_OTLP" != "$BUNDLED_OTLP_ENDPOINT" ]]; then
      upsert_env_var OTEL_EXPORTER_OTLP_ENDPOINT "${BUNDLED_OTLP_ENDPOINT}" "$ENV_FILE"
      if [[ -z "$EXISTING_OTLP" ]]; then
        RECONCILE_CHANGES+=("enabled tracing: OTEL_EXPORTER_OTLP_ENDPOINT=${BUNDLED_OTLP_ENDPOINT}")
      else
        RECONCILE_CHANGES+=("fixed OTEL_EXPORTER_OTLP_ENDPOINT: ${EXISTING_OTLP} → ${BUNDLED_OTLP_ENDPOINT} (OTLP/HTTP receiver)")
      fi
    fi
    OTLP_ENDPOINT_EFFECTIVE="$BUNDLED_OTLP_ENDPOINT"
  fi
fi

if [[ "$FRESH_ENV" != "true" ]] && [[ ${#RECONCILE_CHANGES[@]} -gt 0 ]]; then
  info "Reconciled existing .env (${#RECONCILE_CHANGES[@]} change(s)):"
  for change in "${RECONCILE_CHANGES[@]}"; do
    info "  - ${change}"
  done
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

  # Test basic connectivity.
  #
  # --entrypoint is required, not stylistic. The image's entrypoint is already
  # the node binary, so naming it again in the command position appends instead
  # of replacing: node ends up parsing its own ELF binary and dies with a
  # SyntaxError for every DATABASE_URL, valid or not. api#1134.
  info "Testing database connectivity..."
  DB_TEST_OUTPUT=$(docker run --rm \
    -e DATABASE_URL="${DATABASE_URL}" \
    -e ALLOW_DB_WITHOUT_SSL="${ALLOW_DB_WITHOUT_SSL:-false}" \
    --entrypoint /nodejs/bin/node \
    "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    -e "
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
    # Check PG version >= 17. POSIX sed, not `grep -oP` (\K is GNU-only and
    # BSD grep rejects -P outright); sed prints nothing rather than failing on
    # no match, so the default moves into the expansion.
    PG_MAJOR=$(echo "$PG_VERSION_STR" | sed -n 's/.*PostgreSQL \([0-9][0-9]*\).*/\1/p')
    PG_MAJOR="${PG_MAJOR:-0}"
    if [[ "$PG_MAJOR" -lt 17 ]]; then
      warn "PostgreSQL ${PG_MAJOR} detected. PostgreSQL 17+ recommended."
    fi
  fi

  # Test LISTEN/NOTIFY (pg-boss requirement)
  info "Testing LISTEN/NOTIFY support..."
  LISTEN_OUTPUT=$(docker run --rm \
    -e DATABASE_URL="${DATABASE_URL}" \
    -e ALLOW_DB_WITHOUT_SSL="${ALLOW_DB_WITHOUT_SSL:-false}" \
    --entrypoint /nodejs/bin/node \
    "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    -e "
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

# --- Config Gate ---
#
# `missing_prod_config` reports every production prerequisite the Server
# fail-fasts on, against the finished .env, before the pull. The refusal itself
# was always correct; where the operator found out was not (#1163). See the
# function in lib-compose.sh.
step "Checking configuration"

CONFIG_GAPS=()
# Read loop rather than `mapfile`: macOS ships bash 3.2, which has neither
# mapfile nor readarray (same constraint as the associative array above).
# Process substitution keeps the loop in this shell, so the array survives it.
while IFS= read -r gap_line; do
  CONFIG_GAPS+=("$gap_line")
done < <(missing_prod_config "$ENV_FILE")

if [[ ${#CONFIG_GAPS[@]} -gt 0 ]]; then
  # Headlines start at column 0; remedy lines are indented. Counting headlines
  # counts prerequisites rather than output lines.
  CONFIG_GAP_COUNT=0
  for gap in "${CONFIG_GAPS[@]}"; do
    [[ "$gap" == " "* ]] || CONFIG_GAP_COUNT=$((CONFIG_GAP_COUNT + 1))
  done
  error "${ENV_FILE} is missing ${CONFIG_GAP_COUNT} production prerequisite(s)."
  error "The Server refuses to boot without these, so nothing is started."
  echo ""
  for gap in "${CONFIG_GAPS[@]}"; do
    error "  ${gap}"
  done
  echo ""
  error "Set them in ${ENV_FILE} and re-run this script."
  fatal "Refusing to start a stack that cannot boot."
fi
info "Production prerequisites present"

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

  # Postgres's healthcheck runs inside its own container (pg_isready) and can
  # pass while sibling-container reachability is broken (stale Docker iptables
  # on the compose bridge). Probe before migrate so we fail fast with a clear
  # recovery path instead of letting migrate retry for ~55s on TCP timeout.
  verify_sibling_reachability
fi

# --- Run Migrations ---

step "Running database migrations"

MIGRATE_LOG="$(mktemp)"
if ! "${COMPOSE[@]}" run --rm agledger-migrate 2>&1 | tee "$MIGRATE_LOG"; then
  # 28P01 here is almost always a data volume that outlived the .env it was
  # created with: the migration output is a raw connection error that says
  # nothing about where the mismatch came from.
  if grep -qE '28P01|password authentication failed' "$MIGRATE_LOG" && [[ "${USES_BUNDLED_PG}" == "true" ]]; then
    PGDATA_VOLUME="$(compose_pgdata_volume)"
    echo ""
    error "Postgres rejected the password in ${ENV_FILE} (SQLSTATE 28P01)."
    echo ""
    error "The usual cause is the ${PGDATA_VOLUME} volume being older than that .env. Postgres only"
    error "applies POSTGRES_PASSWORD when it initializes an empty data directory, so a volume from an"
    error "earlier install keeps its original password no matter what .env says now."
    echo ""
    error "Confirm with:  docker volume inspect ${PGDATA_VOLUME} --format '{{.CreatedAt}}'"
    error "If that predates ${ENV_FILE}, either restore the .env that volume was installed with, or"
    error "discard the volume and re-install:  docker volume rm ${PGDATA_VOLUME}"
  elif grep -qE '28P01|password authentication failed' "$MIGRATE_LOG"; then
    error ""
    error "Postgres rejected the credentials in DATABASE_URL (SQLSTATE 28P01). This install uses an"
    error "external database, so check the user and password in ${ENV_FILE}."
  fi
  rm -f "$MIGRATE_LOG"
  MIGRATE_LOG=""
  fatal "Database migrations failed."
fi
rm -f "$MIGRATE_LOG"
MIGRATE_LOG=""
info "Migrations complete"

# --- Create Platform API Key (idempotent on reinstall) ---

# Mint a platform API key against the database this install just migrated, and
# record it in .env. Sets PLATFORM_KEY; returns 1 (leaving PLATFORM_KEY empty)
# when the key could not be read back out of the init output.
mint_platform_key() {
  # docker compose ps --format json reports Networks as a comma-separated STRING,
  # not an object, so `keys[0]` fails. Detect via the running postgres container's
  # actual network attachments, falling back to parsing the Networks string, then
  # finally to the install-repo layout default.
  local compose_network="" postgres_cid init_env init_output
  postgres_cid=$("${COMPOSE[@]}" ps -q postgres 2>/dev/null | head -1 || true)
  if [[ -n "$postgres_cid" ]]; then
    compose_network=$(docker inspect "$postgres_cid" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | awk '{print $1}')
  fi
  if [[ -z "$compose_network" ]]; then
    compose_network=$("${COMPOSE[@]}" ps --format json 2>/dev/null | head -1 | jq -r '.Networks // "" | split(",")[0] // ""' 2>/dev/null || true)
  fi
  if [[ -z "$compose_network" ]]; then
    # No running container to inspect: fall back to the project's default
    # network name (honours COMPOSE_PROJECT_NAME when the install set one).
    compose_network="$(compose_project_name)_default"
  fi
  info "Using compose network: ${compose_network}"

  # Build DATABASE_URL via a temp env file to avoid exposing password in ps output
  init_env=$(mktemp)
  cat "$ENV_FILE" > "$init_env"

  # If using bundled postgres and no DATABASE_URL is set, construct one.
  # bundled_database_url applies the same `:-agledger` defaults the compose
  # files apply, which this `docker run` does not get, and refuses to build a
  # URL with no password rather than handing init one that cannot authenticate.
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && ! grep -q '^DATABASE_URL=' "$init_env"; then
    local bundled_url
    if ! bundled_url=$(bundled_database_url "$ENV_FILE"); then
      rm -f "$init_env"
      # Every `return 1` from here has to leave PLATFORM_KEY empty, because the
      # summary reads it to decide between "SAVE THIS" and the no-credential
      # block. This one returns before the assignment below, so it clears the
      # variable itself: on the 401-replacement path it still holds the reused
      # key, which is the dead one this call was trying to replace.
      PLATFORM_KEY=""
      warn "No POSTGRES_PASSWORD in ${ENV_FILE}; cannot reach the bundled database to mint a key."
      return 1
    fi
    echo "DATABASE_URL=${bundled_url}" >> "$init_env"
  fi
  chmod 600 "$init_env"

  init_output=$(docker run --rm \
    --env-file "$init_env" \
    --network "${compose_network}" \
    "${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}" \
    dist/scripts/init.js --non-interactive 2>&1) || true
  rm -f "$init_env"

  # Extract the platform key from output (look for agl_plt_ prefix). `-oE` is
  # POSIX ERE and works on BSD grep; `-oP` would abort on macOS.
  PLATFORM_KEY=$(echo "$init_output" | grep -oE 'agl_plt_[A-Za-z0-9_-]+' | head -1 || true)

  if [[ -z "$PLATFORM_KEY" ]]; then
    # Not a parsing problem. The platform key is the only credential this
    # install ever produces, so failing to read one back means the install has
    # no way in, and the caller says so again in the summary.
    warn "No platform API key was created. This install has no credential yet."
    echo ""
    echo "--- init output ---"
    echo "$init_output" | grep -v -iE '(password|secret|key_secret)' || true
    echo "--- end output ---"
    return 1
  fi
  info "Platform API key created"
  # Save to .env so upgrade/smoke scripts can use it (file is already chmod 600)
  write_platform_key_to_env "$PLATFORM_KEY" "generated at install"
  info "Platform API key saved to .env"
}

# Rewrite .env so exactly one PLATFORM_API_KEY line exists, carrying $1.
write_platform_key_to_env() {
  local key="$1" provenance="$2" tmp_env
  # grep -v exits 1 when nothing matches the inverse pattern; that's not an
  # error here. The size guard below catches the case where the filter genuinely
  # produced an empty file (which would wipe a real .env).
  tmp_env=$(mktemp)
  grep -vE '^PLATFORM_API_KEY=|^# --- Platform API Key' "$ENV_FILE" > "$tmp_env" || true
  if [[ ! -s "$tmp_env" ]] && [[ -s "$ENV_FILE" ]]; then
    rm -f "$tmp_env"
    fatal "Refusing to truncate .env (filter produced empty output despite non-empty source)"
  fi
  {
    echo ""
    echo "# --- Platform API Key (${provenance}) ---"
    echo "PLATFORM_API_KEY=${key}"
  } >> "$tmp_env"
  chmod 600 "$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
}

# If a platform key is already present in .env from a previous install, reuse
# it instead of minting a new one. Creating a second platform owner ID on
# every reinstall produces duplicate keys and banner confusion. (F-392/F-405)
#
# Reuse is provisional: .env says the key exists, the DATABASE says whether it
# is a credential, and those disagree whenever an .env outlives the data it was
# minted against (a wiped pgdata volume, a restored .env, a copied tree). The
# check runs after the API is up, because a 401 from the running Server is the
# same question the customer's first call asks.
REUSED_PLATFORM_KEY=false
EXISTING_PLATFORM_KEY=""
if grep -qE '^PLATFORM_API_KEY=agl_plt_' "$ENV_FILE" 2>/dev/null; then
  # Use the LAST entry — defensive against older installs that appended
  # multiple lines. We de-dupe below.
  EXISTING_PLATFORM_KEY=$(grep -E '^PLATFORM_API_KEY=agl_plt_' "$ENV_FILE" | tail -1 | cut -d= -f2-)
fi

if [[ -n "$EXISTING_PLATFORM_KEY" ]]; then
  step "Reusing existing platform API key from .env"
  PLATFORM_KEY="$EXISTING_PLATFORM_KEY"
  REUSED_PLATFORM_KEY=true
  # De-dupe, in case an older install appended more than one line.
  write_platform_key_to_env "$PLATFORM_KEY" "from initial install"
  info "Platform API key retained (install is idempotent)"
else
  step "Creating platform API key"
  # `warn` and carry on, because the rest of the install is still worth
  # finishing: the stack comes up, and the recovery below runs against it. The
  # recovery is named here AND in the summary, because a [WARN] a thousand
  # lines up the scrollback is not where the operator is looking when the
  # green banner prints.
  mint_platform_key || {
    warn "Mint one against the running stack with:"
    warn "  cd ${COMPOSE_DIR} && docker compose run --rm \\"
    warn "    --entrypoint /nodejs/bin/node agledger-api dist/scripts/init.js --non-interactive"
  }
fi

# --- Start All Services ---

step "Starting all services"

# `--no-recreate` leaves an existing container alone even when its configuration
# changed, which is right for a no-op re-run and WRONG the moment this run
# reconciled something. Without the distinction, `install.sh --fips` against a
# live stack records AGLEDGER_FIPS=true, adds the overlay, prints "Installation
# Complete", and leaves the containers running with no OPENSSL_CONF: not FIPS,
# and nothing reports it, because an ES256 key signs either way. Same shape for
# a moved host port, a new image pin, or a version bump.
#
# RECONCILE_CHANGES is exactly the set of edits this run made to .env, all of
# which feed container config. When it is non-empty, drop the flag and let
# compose do what it already does well: recreate only the containers whose
# config actually changed.
UP_FLAGS=(--no-recreate)
if [[ ${#RECONCILE_CHANGES[@]} -gt 0 ]]; then
  UP_FLAGS=()
  info "Applying ${#RECONCILE_CHANGES[@]} configuration change(s) to running containers"
fi

# On failure, print the container's own log rather than telling the operator to
# go get it. Compose reports "container is unhealthy" and nothing else, while
# the line that explains it (a config fail-fast naming the missing variable, a
# migration error, a DB refusal) is one `docker compose logs` away. Making the
# operator run that by hand is what turned a single missing key into a
# re-run-per-key loop (#1163).
if ! "${COMPOSE[@]}" up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" agledger-api --wait; then
  error "Failed to start API. Its last 40 log lines:"
  echo ""
  "${COMPOSE[@]}" logs --tail 40 --no-log-prefix agledger-api 2>&1 | sed 's/^/    /' || true
  echo ""
  error "Full log: docker compose logs agledger-api"
  fatal "API did not become healthy."
fi

if [[ "$WITH_MONITORING" == true ]]; then
  "${COMPOSE[@]}" --profile monitoring up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" --wait
else
  "${COMPOSE[@]}" up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" --wait
fi
info "All services started"

# --- Preflight Check ---

step "Running preflight checks"

sleep 5
"${COMPOSE[@]}" exec agledger-api /nodejs/bin/node dist/scripts/preflight.js 2>&1 || {
  warn "Preflight checks returned warnings (non-fatal). Review output above."
}

# --- Summary ---

API_PORT="${API_HOST_PORT}"
API_URL="http://localhost:${API_PORT}"

# --- Verify the reused platform key is a credential on THIS install ---
#
# The reuse decision above read .env; only the database can answer whether the
# key it names exists. They disagree whenever an .env outlives the data it was
# minted against: a wiped pgdata volume, an .env restored onto a fresh
# database, a copied deploy tree. The bootstrap that creates the row is skipped,
# and the install still prints that key under "SAVE THIS", so the operator ends
# up holding a credential that 401s on the instance it was printed for and no
# documented way to mint another.
#
# 401 is specifically "this key hash is not in api_keys" (or it is revoked or
# expired). A real key that simply lacks the role or scope for the probe answers
# 403, so a non-401 is enough to conclude the credential exists.
if [[ "$REUSED_PLATFORM_KEY" == true ]] && [[ -n "${PLATFORM_KEY:-}" ]]; then
  KEY_PROBE_STATUS=""
  for _attempt in 1 2 3; do
    KEY_PROBE_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Authorization: Bearer ${PLATFORM_KEY}" \
      "${API_URL}/v1/records?limit=1" 2>/dev/null || true)"
    [[ -n "$KEY_PROBE_STATUS" && "$KEY_PROBE_STATUS" != "000" ]] && break
    sleep 2
  done
  if [[ "$KEY_PROBE_STATUS" == "401" ]]; then
    warn "The PLATFORM_API_KEY in ${ENV_FILE} is not a credential on this database."
    warn "That .env has outlived the data it was minted against (a recreated volume,"
    warn "a restored .env, or a copied deploy tree). Minting a replacement."
    if mint_platform_key; then
      info "Platform API key replaced; ${ENV_FILE} now holds the working one."
    else
      # mint_platform_key leaves PLATFORM_KEY empty when it fails, so the
      # summary drops into its no-credential block rather than printing the
      # dead key under "SAVE THIS". The one in .env is still the dead one.
      warn "Could not mint a replacement. The PLATFORM_API_KEY still in ${ENV_FILE} does not"
      warn "authenticate; replace it with the key this prints:"
      warn "  cd ${COMPOSE_DIR} && docker compose run --rm \\"
      warn "    --entrypoint /nodejs/bin/node agledger-api dist/scripts/init.js --non-interactive"
    fi
  elif [[ -z "$KEY_PROBE_STATUS" || "$KEY_PROBE_STATUS" == "000" ]]; then
    warn "Could not reach ${API_URL} to confirm the platform API key works. Check it with:"
    warn "  curl -H \"Authorization: Bearer \$PLATFORM_API_KEY\" ${API_URL}/v1/records?limit=1"
  fi
fi

# Read the configured signed issuer (iss) from the generated .env. AGLEDGER_EXTERNAL_URL
# is baked into every signed record/receipt/cert and CANNOT be changed retroactively for
# records already written, so the operator must see it — and be warned if it's still the
# localhost eval default — before notarizing records they intend to keep (cross-repo #813:
# a fresh Compose install signs the chain under iss: http://localhost:3001 by default).
# get_env_value, not a raw grep|cut: it strips the inline comments and trailing
# whitespace .env.example ships, which would otherwise survive into the suffix
# comparison below and make a correct issuer read as a mismatch.
CONFIGURED_ISSUER="$(get_env_value AGLEDGER_EXTERNAL_URL "$ENV_FILE")"
CONFIGURED_ISSUER="${CONFIGURED_ISSUER:-$API_URL}"
ISSUER_IS_LOCALHOST=false
case "$CONFIGURED_ISSUER" in
  http://localhost*|https://localhost*|http://127.0.0.1*|https://127.0.0.1*)
    ISSUER_IS_LOCALHOST=true
    ;;
esac

# Whether the issuer names an explicit port at all, which is a narrower question
# than being a localhost URL. `https://localhost` with no port is the documented
# escape hatch for a domain-less single node, and it is not a port mismatch: it
# names no port to disagree with. Comparing it against ":${API_HOST_PORT}"
# without this would fire the mismatch banner on every install that uses it.
ISSUER_NAMES_A_PORT=false
case "$CONFIGURED_ISSUER" in
  http://localhost:*|https://localhost:*|http://127.0.0.1:*|https://127.0.0.1:*)
    ISSUER_NAMES_A_PORT=true
    ;;
esac

# What this Server actually signs with, read from the Server rather than from
# what we asked for: on a re-run over an existing .env the request may not be
# what is installed, and the key document is the same thing every consumer
# reads. `minVerifierVersion` is published per key, so the floor quoted below
# is the engine's own answer, not a number hardcoded here.
VAULT_KEY_DOC=""
for _attempt in 1 2 3; do
  VAULT_KEY_DOC="$(curl -sf --max-time 5 "${API_URL}/v1/verification-keys" 2>/dev/null || true)"
  [[ -n "$VAULT_KEY_DOC" ]] && break
  sleep 2
done
ACTIVE_SIGNING_ALG=""
MIN_VERIFIER_VERSION=""
if [[ -n "$VAULT_KEY_DOC" ]]; then
  ACTIVE_SIGNING_ALG="$(echo "$VAULT_KEY_DOC" | jq -r '.signatureAlgorithm // empty' 2>/dev/null || true)"
  MIN_VERIFIER_VERSION="$(echo "$VAULT_KEY_DOC" | jq -r '[.data[] | select(.status == "active") | .minVerifierVersion] | first // empty' 2>/dev/null || true)"
fi

# The non-default-algorithm banner below is the one place the verifier floor
# reaches the operator, so it must not depend on a network read succeeding. If
# the key document could not be fetched, fall back to what this run configured:
# on a fresh install that is authoritative, and on a re-run the recorded opt-in
# says whether the key is non-default even when we cannot name the algorithm.
if [[ -z "$ACTIVE_SIGNING_ALG" ]]; then
  if [[ "$FRESH_ENV" == true && "$SIGNING_ALGORITHM" != "ed25519" ]]; then
    ACTIVE_SIGNING_ALG="$(echo "$SIGNING_ALGORITHM" | tr '[:lower:]' '[:upper:]')"
  elif [[ "$(get_env_value AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG "$ENV_FILE")" == "true" ]]; then
    ACTIVE_SIGNING_ALG="a non-default algorithm"
  fi
fi

echo ""
# The header states the outcome, not the fact that the script reached its last
# line. With no credential the stack is running and unusable, and a green
# "Complete" is the wrong first thing to read.
if [[ -z "${PLATFORM_KEY:-}" ]]; then
  echo -e "${RED}=============================================================================${NC}"
  echo -e "${RED}  AGLedger: installed, but NOT usable (no platform API key)${NC}"
  echo -e "${RED}=============================================================================${NC}"
else
  echo -e "${GREEN}=============================================================================${NC}"
  echo -e "${GREEN}  AGLedger — Installation Complete${NC}"
  echo -e "${GREEN}=============================================================================${NC}"
fi
echo ""
echo -e "  ${BOLD}Version:${NC}       ${AGLEDGER_VERSION}"
echo -e "  ${BOLD}API URL:${NC}       ${API_URL}"
echo -e "  ${BOLD}Signed issuer:${NC} ${CONFIGURED_ISSUER}  (iss baked into every record)"
if [[ -n "$ACTIVE_SIGNING_ALG" ]]; then
  echo -e "  ${BOLD}Signing:${NC}       ${ACTIVE_SIGNING_ALG}"
fi
echo -e "  ${BOLD}Health:${NC}        ${API_URL}/health"
echo -e "  ${BOLD}Conformance:${NC}   ${API_URL}/v1/conformance"
echo -e "  ${BOLD}OpenAPI spec:${NC}  ${API_URL}/openapi.json"
echo -e "  ${BOLD}Agent guide:${NC}   ${API_URL}/llms.txt"
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
else
  # The absence of this block used to be the only difference between this
  # banner and a good install's, which made an install with no way in read as
  # a complete one.
  echo -e "  ${BOLD}${RED}⚠ No platform API key. This install has no credential.${NC}"
  echo ""
  echo -e "    Every /v1 and /admin call needs one, so nothing can be recorded until"
  echo -e "    you mint it. The stack is up and the database is migrated; this is the"
  echo -e "    last step, and it runs against what is already running:"
  echo ""
  echo -e "      ${YELLOW}cd ${COMPOSE_DIR} && docker compose run --rm \\\\${NC}"
  echo -e "      ${YELLOW}  --entrypoint /nodejs/bin/node agledger-api dist/scripts/init.js --non-interactive${NC}"
  echo ""
  echo -e "    It prints the key once. Copy it into PLATFORM_API_KEY in ${ENV_FILE}."
  echo -e "    The [WARN] block earlier in this run carries the init output that explains why."
fi

if [[ "$WITH_MONITORING" == true ]]; then
  echo ""
  echo -e "  ${BOLD}Monitoring:${NC}"
  echo -e "    Jaeger UI:     http://localhost:${JAEGER_HOST_PORT}"
  echo -e "    Prometheus:    http://localhost:${PROM_HOST_PORT}"
  case "$GRAFANA_PASSWORD_STATE" in
    generate)
      echo -e "    Grafana:       http://localhost:${GRAF_HOST_PORT} (admin / ${YELLOW}${GRAFANA_ADMIN_PASSWORD}${NC}, also in ${ENV_FILE})"
      ;;
    stale)
      echo -e "    Grafana:       http://localhost:${GRAF_HOST_PORT} (admin / unchanged from this volume's first boot; see the warning above)"
      ;;
    *)
      echo -e "    Grafana:       http://localhost:${GRAF_HOST_PORT} (admin / see GRAFANA_ADMIN_PASSWORD in ${ENV_FILE})"
      ;;
  esac
  echo -e "    Tracing:       on (OTEL_EXPORTER_OTLP_ENDPOINT=${OTLP_ENDPOINT_EFFECTIVE})"
fi

echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo -e "    Learn what AGLedger does:   https://agledger.ai/how-it-works"
echo -e "    Self-hosted install guide:  https://agledger.ai/docs/guides/self-hosted/install"
echo -e "    API reference (hosted):     https://agledger.ai/api"
echo -e "    Container status:           docker compose ps"

# The people who have to upgrade their verifier are usually not the operator
# running this script, so the floor has to be stated here, at the moment the
# operator decides they are done. Ed25519 is the default and needs no callout.
if [[ -n "$ACTIVE_SIGNING_ALG" && "$ACTIVE_SIGNING_ALG" != "Ed25519" ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠ This Server signs with ${ACTIVE_SIGNING_ALG}, not the default Ed25519${NC}"
  if [[ -n "$MIN_VERIFIER_VERSION" ]]; then
    echo -e "    Anyone verifying this chain offline needs @agledger/verify >= ${MIN_VERIFIER_VERSION}."
    echo -e "    The algorithm support lives in its @agledger/verify-core dependency; that floor"
    echo -e "    is the @agledger/verify release which resolves a core carrying it under every"
    echo -e "    install shape, which is why it is the version to quote."
    echo -e "    Tell whoever consumes your exports BEFORE they run one. A verifier that cannot"
    echo -e "    compute the algorithm does not always say so: recent builds report"
    echo -e "    CHAIN_UNSUPPORTED_ALGORITHM and name the fix, but older ones report a signature"
    echo -e "    failure, which reads as tampering on a chain that is perfectly intact."
  else
    echo -e "    Anyone verifying this chain offline needs a verifier release that supports"
    echo -e "    ${ACTIVE_SIGNING_ALG}. Check ${API_URL}/v1/verification-keys for minVerifierVersion."
  fi
  echo -e "    Federation is not available on this configuration, and agent surfaces pinned to"
  echo -e "    Ed25519 (webhook signingAlg: ed25519) refuse with an error naming what to use."
  if fips_overlay_enabled; then
    echo -e "    The OpenSSL FIPS provider is active in every container (AGLEDGER_FIPS=true)."
    echo -e "    Confirm with: docker compose exec agledger-api /nodejs/bin/node -e \\"
    echo -e "      \"console.log(require('crypto').getFips())\"   (1 means active)"
  else
    echo -e "    This Server signs with ES256 but is NOT running the OpenSSL FIPS provider."
    echo -e "    To activate it, re-run the installer with --fips."
  fi
  echo -e "    See the FIPS section of the install README."
fi

# An issuer naming a port this stack does not serve survives only the case the
# reconcile above deliberately declines to touch: a database that may already
# hold records signed under it. That is a real decision the operator has to
# make, so it belongs in the summary and not only in a [WARN] a thousand lines
# up the scrollback (#1128).
#
# "names a port" is the gate, not "is localhost": a port-less issuer disagrees
# with nothing.
if [[ "$ISSUER_NAMES_A_PORT" == true && "$CONFIGURED_ISSUER" != *":${API_HOST_PORT}" ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠ Signed issuer names a port this stack does not serve${NC}"
  echo -e "    AGLEDGER_EXTERNAL_URL=${CONFIGURED_ISSUER}, but the API is on ${API_URL}."
  echo -e "    That URL is the iss on every record written from now on, and the address an"
  echo -e "    auditor follows out of /audit-export to fetch your verification keys. It now"
  echo -e "    points at whatever else answers on that port, which may be nothing, or may be"
  echo -e "    a different Server whose published keys will not match this export."
  echo -e "    Left alone because records signed under it may already exist. Either:"
  echo -e "      keep it   any earlier records stay consistent, new ones inherit the bad URL"
  echo -e "      change it in ${ENV_FILE}, then docker compose up -d"
  echo -e "                new records resolve, any earlier ones keep the old iss"
fi

if [[ "$ISSUER_IS_LOCALHOST" == true ]]; then
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠ Signed issuer is a localhost default${NC}"
  echo -e "    AGLEDGER_EXTERNAL_URL=${CONFIGURED_ISSUER} is the iss signed into every record,"
  echo -e "    receipt, and cert — and it cannot be changed for records already written."
  echo -e "    Fine for evaluation. Before notarizing records you intend to keep, set"
  echo -e "    AGLEDGER_EXTERNAL_URL to your real https:// domain in ${ENV_FILE} and restart."
fi

echo ""
if [[ -z "${PLATFORM_KEY:-}" ]]; then
  echo -e "${RED}=============================================================================${NC}"
else
  echo -e "${GREEN}=============================================================================${NC}"
fi

# An install that produced no credential is not one an operator or an agent can
# use, and the exit code is the signal automation reads before it reads any
# banner. Re-running install.sh is the supported recovery and is idempotent, so
# a caller that retries on non-zero does the right thing.
if [[ -z "${PLATFORM_KEY:-}" ]]; then
  EXIT_ALREADY_EXPLAINED=true
  exit 1
fi
