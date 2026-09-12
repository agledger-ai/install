#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — First-Run Installer
# =============================================================================
# Usage:
#   ./scripts/install.sh
#   ./scripts/install.sh --version 0.15.6
#   ./scripts/install.sh --non-interactive --version 0.15.6 --with-monitoring
#   ./scripts/install.sh --external-db --non-interactive
#   ./scripts/install.sh --image your-registry.com/agledger --version 0.15.6
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

# Accepted and kept, because agl-deploy.sh and every scripted caller passes it,
# but this installer asks no questions: there is not a single `read` in it, and
# each decision that could have been a prompt is a flag or a refusal with the
# command to re-run. Nothing consults the variable for that reason. Do not
# "wire it up" by adding a prompt for it to suppress.
NON_INTERACTIVE=false
WITH_MONITORING=false
REQUESTED_VERSION=""
EXTERNAL_DB_FLAG=false
FIPS_FLAG=false
CUSTOM_IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      # shellcheck disable=SC2034  # see the declaration: nothing here prompts
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
      echo "  --non-interactive    Accepted for scripted callers. This installer never prompts."
      echo "  --version VERSION    AGLedger version to install (default: the version this install is already on, or latest stable from Docker Hub for a fresh install)"
      echo "  --image IMAGE        Container image (default: agledger/agledger)"
      echo "  --with-monitoring    Enable monitoring stack (Jaeger, Prometheus, Grafana)"
      echo "  --external-db        Skip bundled PostgreSQL (DATABASE_URL must be set in .env)"
      echo "  --fips               Run containers with the OpenSSL FIPS provider active."
      echo "                       Implies ES256 signing: the provider cannot compute Ed25519."
      echo "  --skip-verify        Skip image signature verification (dev/local ONLY — never production)"
      echo "  -h, --help           Show this help message"
      echo ""
      echo "Environment:"
      echo "  AGLEDGER_REQUIRE_VERIFY=true   Refuse to install when the image cannot be verified."
      echo "                       Without it the install proceeds unverified (with a warning) on a"
      echo "                       host that has no cosign. Set it for production and in CI."
      echo "  ECR_REGISTRY         Registry host to authenticate against. Only needed when it differs"
      echo "                       from the host in --image, which is used otherwise."
      echo "  AWS_REGION           Region for the ECR login, when the host does not carry one."
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
# so a registry port (e.g. localhost:5000/agledger) isn't mistaken for one.
#
# A digest ref is refused rather than carried through. The same composition
# turns `repo@sha256:abc` into `repo@sha256:abc:1.4.0`, which docker rejects
# with a parse error naming neither flag. There is also nothing to gain by
# accepting one: this script resolves the digest itself and pins the stack to
# it, so a caller-supplied digest only restates what verification already
# establishes.
if [[ -n "$CUSTOM_IMAGE" ]]; then
  if [[ "$CUSTOM_IMAGE" == *@* ]]; then
    fatal "--image takes a repository, not a digest ref (${CUSTOM_IMAGE}). Pass the repository (e.g. ${CUSTOM_IMAGE%%@*}) with --version; the installer resolves the digest itself and pins compose/.env to it. (Signature verification covers the official agledger/agledger image only — a custom registry is pinned, not verified.)"
  fi
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
COMPOSE_VERSION=$(docker compose version --short 2>/dev/null || echo "unknown")
# The floor and the parsing live in lib-compose.sh, because upgrade.sh reads the
# same compose file and needs the same answer. See compose_version_state.
COMPOSE_STATE="$(compose_version_state)"
if [[ "$COMPOSE_STATE" != "ok" ]]; then
  fatal "${COMPOSE_STATE} This stack's compose file uses an inline \`configs.content\`, which older Compose fails to PARSE, so up, down, logs and ps all break. Upgrade: https://docs.docker.com/compose/install/"
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
    error "  rm -rf backup                              # the first install's archives are not this one's"
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

# The registry has to be resolved before version resolution runs, not after:
# resolve_latest_version (lib-compose.sh) and the private-registry guard in the
# version case statement below both read AGLEDGER_IMAGE, and it was still
# reading the "agledger/agledger" default at that point for a PERSISTED (not
# re-flagged) private registry. The documented air-gap flow is exactly that
# shape on its first real run: .env already names the private registry from an
# earlier step, no --image, no --version, no install state yet, so a flagless
# `install.sh` resolved a Docker Hub release number and only failed later,
# inside verify_image, pulling that tag from the private registry. The "Image
# Registry" step below still owns reporting this and authenticating; only the
# read is pulled forward.
if [[ -z "$CUSTOM_IMAGE" ]]; then
  PERSISTED_IMAGE=$(get_env_value AGLEDGER_IMAGE "${COMPOSE_DIR}/.env")
  [[ -n "$PERSISTED_IMAGE" ]] && AGLEDGER_IMAGE="$PERSISTED_IMAGE"
fi

# --- Version Resolution ---

step "Resolving version"

# `install_version_decision` (lib-compose.sh) owns the rule and carries the
# reasoning; this block is the reporting around it.
INSTALLED_VERSION=$(get_env_value AGLEDGER_VERSION "${COMPOSE_DIR}/.env")
HAS_INSTALL_STATE=false
if env_file_carries_install_state "${COMPOSE_DIR}/.env"; then HAS_INSTALL_STATE=true; fi
VERSION_DECISION=$(install_version_decision "$REQUESTED_VERSION" "$INSTALLED_VERSION" "$HAS_INSTALL_STATE")
AGLEDGER_VERSION="${VERSION_DECISION%|*}"
VERSION_SOURCE="${VERSION_DECISION##*|}"

case "$VERSION_SOURCE" in
  requested)
    info "Version: ${AGLEDGER_VERSION} (requested)"
    if [[ -n "$INSTALLED_VERSION" && "$INSTALLED_VERSION" != "$AGLEDGER_VERSION" ]]; then
      # Explicit, so it is honored: naming a version is how an operator moves
      # an install deliberately. It is still a version change on a live install,
      # and the migrations below run with nothing backed up.
      warn "This install is at ${INSTALLED_VERSION} and you asked for ${AGLEDGER_VERSION}. That is a VERSION CHANGE, not a re-install."
      warn "This script takes NO backup and writes no rollback marker. If this database holds records you care about,"
      warn "stop now and use instead:  ./scripts/upgrade.sh ${AGLEDGER_VERSION}"
      warn "which backs up first and records what to roll back to."
    fi
    ;;
  installed)
    info "Version: ${AGLEDGER_VERSION} (the version this install is already on)"
    info "Re-running the installer does not move a version. To change releases:  ./scripts/upgrade.sh <VERSION>"
    ;;
  ambiguous)
    # AGLEDGER_VERSION here is the recorded tag itself (install_version_decision
    # carries it through unchanged), not something to install on. Three shapes
    # reach here, and only one of them has a version-preserving command to hand
    # back:
    #   - genuinely empty: real install state with no AGLEDGER_VERSION line at
    #     all, from an install that predates this script recording one.
    #   - the literal string "latest": the .env.example placeholder. It reads
    #     like a version but is a floating tag, so playing it back with
    #     --version does not restore what is running, it resolves to whatever
    #     Docker Hub's latest tag means TODAY - the opposite of a no-op.
    #   - anything else non-release: a deliberate pin (a testbed build, an
    #     air-gap mirror tag) this installer cannot tell from the placeholder.
    # The first two have no tag worth playing back, so both point at reading
    # the version actually running instead.
    RECORDED_TAG="$AGLEDGER_VERSION"
    if [[ -z "$RECORDED_TAG" ]]; then
      error "This install has real install state (a platform key and/or a signing key) but"
      error "no recorded AGLEDGER_VERSION at all, so this installer cannot tell what version"
      error "is actually running without moving it to resolve one. Read the version this"
      error "install runs today, then pass it explicitly:"
      error ""
      error "  docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps          # IMAGE column names the running tag"
      error "  curl -s http://localhost:${API_HOST_PORT}/health/ready         # or the running API's own \"version\" field"
      error ""
      error "  ./scripts/install.sh --version <that version>"
      fatal "Refusing to resolve a version for an install with no recorded version."
    fi
    if [[ "$RECORDED_TAG" == "latest" ]]; then
      error "This install's recorded AGLEDGER_VERSION is the literal string 'latest', the"
      error ".env.example placeholder. It reads like a version but is a floating tag:"
      error "passing it back as --version does not restore what is running, it resolves to"
      error "whatever Docker Hub's latest tag means right now, almost certainly a newer"
      error "release than whatever this install started on. Read the version actually"
      error "running, then pass it explicitly:"
      error ""
      error "  docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps          # IMAGE column names the running tag"
      error "  curl -s http://localhost:${API_HOST_PORT}/health/ready         # or the running API's own \"version\" field"
      error ""
      error "  ./scripts/install.sh --version <that version>"
      error ""
      error "To move to a newer release instead (backs up first, writes a rollback marker):"
      error "  ./scripts/upgrade.sh <VERSION>"
      fatal "Refusing to resolve a version for an install pinned to the floating 'latest' tag."
    fi
    error "This install's recorded AGLEDGER_VERSION is '${RECORDED_TAG}', which is not a release"
    error "number, so this installer cannot tell a deliberate pin (a testbed build, an"
    error "air-gap mirror tag) from the .env.example placeholder ('latest') never"
    error "overwritten. A plain re-run cannot resolve that safely, so it refuses rather"
    error "than silently moving the install to whatever Docker Hub currently calls latest."
    error ""
    error "To stay on '${RECORDED_TAG}' (re-install path, no version change, so long as your"
    error "registry keeps that tag pointing at what it did when this install started):"
    error "  ./scripts/install.sh --version ${RECORDED_TAG}"
    error ""
    error "To move to a specific release (backs up first, writes a rollback marker):"
    error "  ./scripts/upgrade.sh <VERSION>"
    fatal "Refusing to resolve a version for an install pinned to a non-release tag."
    ;;
  *)
    if [[ "${AGLEDGER_IMAGE}" != "agledger/agledger" ]]; then
      fatal "No --version given, and the image is ${AGLEDGER_IMAGE}, not Docker Hub's agledger/agledger. Its tag list is not Docker Hub's, so 'latest' cannot be resolved from there. Re-run with --version <tag>."
    fi
    info "Looking up latest version from Docker Hub..."
    if ! AGLEDGER_VERSION=$(resolve_latest_version); then
      fatal "Could not determine latest version (network failure, no cache). Re-run with --version X.Y.Z to pin a specific release. See https://hub.docker.com/r/agledger/agledger/tags"
    fi
    info "Version: ${AGLEDGER_VERSION} (latest from Docker Hub)"
    ;;
esac

# --- Image Registry ---

# `--image` names a registry for the life of the install, not for one process.
# A run that does not name one adopts what the last install wrote, so
# re-running this script against a private-registry install keeps pulling from
# that registry instead of silently reverting to Docker Hub. An explicit
# `--image` always wins, which is also how an operator moves an install back to
# Docker Hub (`--image agledger/agledger`).
#
# AGLEDGER_IMAGE was already resolved from .env above, before version
# resolution needed to see it. This just reports it.
if [[ -z "$CUSTOM_IMAGE" ]] && [[ -n "${PERSISTED_IMAGE:-}" ]]; then
  info "Using the registry this install was configured with: ${AGLEDGER_IMAGE}"
fi

if [[ "${AGLEDGER_IMAGE}" != "agledger/agledger" ]]; then
  step "Authenticating with private registry"
  ecr_login
else
  info "Using Docker Hub: ${AGLEDGER_IMAGE}"
fi

# --- Verify Image Signature (before anything executes it) ---
# The image is run below to mint the vault signing key, so it must be proven
# genuine first. Sets RESOLVED_DIGEST; we pin the running stack to that digest.
# Exit 2 is "the image never downloaded", which is an authentication or
# connectivity problem and not a signature one. Reporting it as a signature
# failure sends an operator to cosign, keys and Rekor for what is a
# `docker login`.
#
# Captured, not read from `$?` after a bare call: under `set -e` a non-zero
# return from a function invoked as its own command exits the script at that
# line, so neither message below ever printed and an operator whose pull failed
# for missing registry credentials was sent to the generic failure text.
VERIFY_STATUS=0
verify_image "$AGLEDGER_IMAGE" "$AGLEDGER_VERSION" || VERIFY_STATUS=$?
case $VERIFY_STATUS in
  0) ;;
  2)
    # AGLEDGER_REQUIRE_VERIFY first, because `verify_image` never reaches its own
    # copy of this check: the pull failure returns 2 from above every one of
    # them. An operator who set the flag asked for a refusal in exactly this
    # case, and the fallback below cannot honour it: a local pin proves the bytes
    # are the ones .env names and says nothing about whether anything ever
    # verified them, and cosign cannot verify against an unreachable registry.
    if [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
      fatal "Could not pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}, and AGLEDGER_REQUIRE_VERIFY=true. Refusing to continue on bytes this run did not verify."
    fi
    # A failed pull is a statement about the network, not about the image, and
    # this script is also the documented way to reconcile an existing install's
    # configuration. Refusing outright meant an air-gapped host, or one whose
    # registry was briefly down, could reach none of the repairs below: no
    # metrics token, no federation identity, no monitoring profile, on a machine
    # whose containers were already running the exact bytes .env pins.
    #
    # So the fatal is kept for every case where this run would have to RUN
    # something new, and dropped for the one case where it does not: the pin in
    # .env is a digest, and that digest is in this host's local image store.
    # Nothing is verified here, which is why the output says so and the run
    # carries on with SIGNATURE_VERIFIED false.
    # Three conditions, not one. The pin has to name the registry this run
    # resolved (`--image` moves an install, and reusing the old registry's
    # digest under the new name would write a ref that does not exist), and it
    # has to belong to the version this run is installing (a pin from an earlier
    # release is old bytes, and continuing on them would label them as the new
    # version). Only then does "the bytes are already here" mean anything.
    OFFLINE_PIN=$(get_env_value AGLEDGER_IMAGE_PIN "${COMPOSE_DIR}/.env")
    OFFLINE_PINNED_VERSION=$(get_env_value AGLEDGER_VERSION "${COMPOSE_DIR}/.env")
    if [[ -n "$OFFLINE_PIN" ]] \
      && [[ "${OFFLINE_PIN%%@*}" == "$AGLEDGER_IMAGE" ]] \
      && [[ "$OFFLINE_PINNED_VERSION" == "$AGLEDGER_VERSION" ]] \
      && local_image_matches_pin "$OFFLINE_PIN"; then
      warn "Could not pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}, but ${COMPOSE_DIR}/.env already pins"
      warn "  ${OFFLINE_PIN}"
      warn "and those exact bytes are in this host's local image store. Continuing on them so this"
      warn "run can still reconcile configuration. NOTHING WAS VERIFIED on this run: the pin keeps"
      warn "whatever verdict the run that wrote it recorded."
      RESOLVED_DIGEST="${OFFLINE_PIN##*@}"
      SIGNATURE_VERIFIED=false
      UNVERIFIED_REASON="registry unreachable; reused the digest already pinned in .env"
    else
      if [[ "${IMAGE_PRESENT_LOCALLY:-false}" == "true" ]]; then
        # The bytes are here; what is missing is any way to check them on this
        # run. Repeating "the image never arrived" as the last line an operator
        # reads contradicts the refusal above it and sends them after an image
        # `docker image inspect` resolves in front of them.
        fatal "Could not pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}, and nothing on this run verified the copy already in this host's image store. See the guidance above."
      fi
      fatal "Could not pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION} — see the authentication guidance above. Nothing was verified, because the image never arrived."
    fi
    ;;
  *) fatal "Image signature verification failed — aborting before running an unverified image." ;;
esac
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

# Every edit this run makes to .env that changes what a container receives.
# Declared HERE, above the secret backfills, and not at the reconciliation
# section further down, because the backfills are edits of exactly that kind and
# they run first: a re-run that mints a missing METRICS_AUTH_TOKEN on a host
# whose .env predates the gating wrote the token, appended nothing, and reached
# the start step with the list still empty, so `up -d --no-recreate` left the
# API, worker and bundled Prometheus on the environment they booted with. The
# banner said the install was complete and /metrics kept answering 401.
RECONCILE_CHANGES=()

# Refusing to write credentials that cannot authenticate against a Postgres
# data directory some earlier install left behind. Reached from two places: a
# fresh .env (`stale_pgdata_blocks_install`), and a pre-existing .env that
# carries no POSTGRES_PASSWORD, which lands on the same hazard by the other
# door. Postgres skips initialization on a populated data directory, so
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
  error "  rm -rf backup                              # nor its backup archives and rollback marker"
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
  # the whole problem here. `--external-db` documents writing DATABASE_URL into
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
# it is actually missing.

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
    RECONCILE_CHANGES+=("generated POSTGRES_PASSWORD")
    info "Generated POSTGRES_PASSWORD"
    ;;
esac

# A federation identity, whether or not this install ever federates. It costs
# nothing on a Server that does not (it is an identifier, not a secret, and
# nothing reads it until a peer handshake), and it is the difference between
# federation working and dead-ending: without it the Server reports the literal
# "default" to its operator, and the peer's handshake refuses that value
# because `peerHubId` is declared `format: uuid`. Generated here rather
# than defaulted in the engine because it has to be STABLE across restarts, and
# .env is what survives a container.
HUB_ID_ACTION="$(federation_hub_id_action "$ENV_FILE")"
case "$HUB_ID_ACTION" in
  generate)
    AGLEDGER_INSTANCE_ID_VALUE=$(generate_uuid) \
      || fatal "Failed to generate AGLEDGER_INSTANCE_ID"
    upsert_env_var AGLEDGER_INSTANCE_ID "${AGLEDGER_INSTANCE_ID_VALUE}" "$ENV_FILE"
    RECONCILE_CHANGES+=("generated AGLEDGER_INSTANCE_ID (this Server's federation identity; it had none)")
    info "Generated AGLEDGER_INSTANCE_ID (this Server's federation identity)"
    ;;
  adopt-legacy-org-id:*)
    # The retired AGLEDGER_ORGANIZATION_ID fallback was this Server's identity
    # and peers may hold it. Carry it forward rather than mint a new one.
    upsert_env_var AGLEDGER_INSTANCE_ID "${HUB_ID_ACTION#adopt-legacy-org-id:}" "$ENV_FILE"
    RECONCILE_CHANGES+=("adopted AGLEDGER_ORGANIZATION_ID as AGLEDGER_INSTANCE_ID")
    info "Adopted AGLEDGER_ORGANIZATION_ID as AGLEDGER_INSTANCE_ID (the identity peers already hold); AGLEDGER_ORGANIZATION_ID can be deleted from .env"
    ;;
esac

if [[ -z "$(get_env_value API_KEY_SECRET "$ENV_FILE")" ]]; then
  info "Generating API_KEY_SECRET..."
  API_KEY_SECRET=$(openssl rand -hex 32) \
    || fatal "Failed to generate API_KEY_SECRET"
  upsert_env_var API_KEY_SECRET "${API_KEY_SECRET}" "$ENV_FILE"
  RECONCILE_CHANGES+=("generated API_KEY_SECRET")
  info "Generated API_KEY_SECRET"
fi

# /metrics is gated under NODE_ENV=production, which .env.example sets. Without
# a token the endpoint answers the API-key chain and the bundled Prometheus
# scrapes 401s, which shows up as a target that is simply down. The token is
# what the prometheus service reads (docker-compose.yml projects it as a file),
# so generate one the same way as every other secret: once, then never again.
if [[ -z "$(get_env_value METRICS_AUTH_TOKEN "$ENV_FILE")" ]]; then
  METRICS_AUTH_TOKEN=$(openssl rand -hex 24) \
    || fatal "Failed to generate METRICS_AUTH_TOKEN"
  upsert_env_var METRICS_AUTH_TOKEN "${METRICS_AUTH_TOKEN}" "$ENV_FILE"
  RECONCILE_CHANGES+=("generated METRICS_AUTH_TOKEN (bearer token for /metrics; it had none)")
  info "Generated METRICS_AUTH_TOKEN (bearer token for /metrics)"
fi

if [[ "$HAS_SIGNING_KEY" != true ]]; then
  # A non-default algorithm also writes the AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG
  # acknowledgment below (chain consumers need a verifier release that supports it).
  info "Generating VAULT_SIGNING_KEY (${SIGNING_ALGORITHM})..."
  # Run the digest-pinned ref (falls back to tag only when no digest resolved).
  # These are the bytes that mint the install's root signing key, so whether
  # they were verified is the whole question — and on a cosign-less host or a
  # custom image they were not. The step that reports the pin says which it
  # was; this line must not claim more than that one does.
  VAULT_SIGNING_KEY_OUTPUT=$(docker run --rm "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    dist/scripts/generate-signing-key.js --algorithm "$SIGNING_ALGORITHM" 2>/dev/null) \
    || fatal "Failed to generate VAULT_SIGNING_KEY. Is the image available? Try: docker pull ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}"
  VAULT_SIGNING_KEY=$(echo "$VAULT_SIGNING_KEY_OUTPUT" | parse_signing_key || true)
  if [[ -z "$VAULT_SIGNING_KEY" ]]; then
    fatal "Could not parse VAULT_SIGNING_KEY from output"
  fi
  upsert_env_var VAULT_SIGNING_KEY "${VAULT_SIGNING_KEY}" "$ENV_FILE"
  RECONCILE_CHANGES+=("generated VAULT_SIGNING_KEY (${SIGNING_ALGORITHM})")
  if [[ "$SIGNING_ALGORITHM" == "es256" ]]; then
    upsert_env_var AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG true "$ENV_FILE"
    RECONCILE_CHANGES+=("set AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true (non-default algorithm opt-in)")
    info "Wrote AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG=true (non-default algorithm opt-in)"
  fi
  info "Generated VAULT_SIGNING_KEY"
fi

chmod 600 "$ENV_FILE"

# --- Detect Database Mode ---

# Source .env to pick up DATABASE_URL if customer pre-configured it.
#
# Everything resolved above has already had its turn in the precedence chain
# (flag, then .env, then default), so .env must not get a second turn on the
# way back. Each of these was a silent no-op install before it was held:
#
#   AGLEDGER_VERSION     a fresh .env from .env.example carries `latest`, so
#                        the source installed :latest over an explicit
#                        --version.
#   AGLEDGER_IMAGE       --image named a new registry, the run authenticated,
#                        pulled and signature-checked from it, and then wrote
#                        the old registry back to .env and left the stack on
#                        it. A revert to Docker Hub never happened either.
#   AGLEDGER_IMAGE_PIN   the digest just verified was replaced by the one from
#                        the previous install, so .env named a version the
#                        stack was not running. (The pin is empty when the ref
#                        carries no usable RepoDigest: the registry reported
#                        none, or no registry was reached at all and the run is
#                        continuing on an image already in the local store. The
#                        reconciliation below reports that rather than acting on
#                        it silently.)
snapshot_resolved_var AGLEDGER_VERSION
snapshot_resolved_var AGLEDGER_IMAGE
snapshot_resolved_var AGLEDGER_IMAGE_PIN
# The project name is the same hazard and worse: compose reads an exported
# COMPOSE_PROJECT_NAME in preference to the one in .env, so letting the source
# overwrite it would create the stack under the requested project while
# recording the old one in .env. Every later bare `docker compose` command
# (and upgrade.sh) would then address the wrong stack. Held separately because
# an unset one means "no request", not "restore empty".
REQUESTED_PROJECT="${COMPOSE_PROJECT_NAME:-}"
# Read, not `source`: the shell is a parser of its own and disagrees with
# compose on a DATABASE_URL carrying more than one query parameter (see
# load_env_file). Unquoted, `&` backgrounded the assignment and this run aborted
# with "External database mode requires DATABASE_URL in .env" over a file that
# sets it.
load_env_file "$ENV_FILE"
restore_resolved_vars
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
# Runs on BOTH fresh and existing .env so the COMPOSE_FILE and version-tracking fixes
# reach customers who installed at v0.19.16 and re-run install.sh at v0.19.17+.
# Never auto-flips security-sensitive values — only adds missing keys and
# updates version-tracking keys.
#
# RECONCILE_CHANGES is declared with the secret backfills above, which append to
# it for the same reason this section does.

# Persist COMPOSE_FILE so manual `docker compose` commands from compose/
# pick up all overlays (prod + optional bundled postgres). Without this, manual
# commands drop to bare docker-compose.yml and the postgres container stops
# reacting to `restart`.
build_overlay_list

# Setting COMPOSE_FILE is what turns Compose's automatic docker-compose.override.yml
# discovery off, so build_overlay_list appends the override file itself when one
# exists. Name it: an operator who wrote one has no other confirmation that it is
# being applied, and one forgotten from an earlier experiment is worth saying out
# loud before the stack comes up with it.
COMPOSE_OVERRIDE_FILE="$(compose_override_file)"
if [[ -n "$COMPOSE_OVERRIDE_FILE" ]]; then
  warn "Applying ${COMPOSE_OVERRIDE_FILE} on top of the shipped compose files. Remove it if that is not what you want."
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
#                            a dead issuer, silently.
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
    # no issuer and the container fatally exited on config load. A
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

# Persist the registry alongside the pin. The pin is a digest ref and cannot
# stand in for it: upgrade.sh sources this file, and with no AGLEDGER_IMAGE in
# it falls back to `agledger/agledger`, so a private-registry install skipped
# the registry login on upgrade and pulled the next version from Docker Hub —
# failing outright where Docker Hub is unreachable, and where the same tags
# exist on both, quietly moving the install off the registry the operator
# chose.
EXISTING_IMAGE=$(get_env_value AGLEDGER_IMAGE "$ENV_FILE")
case "$(image_line_action "$AGLEDGER_IMAGE" "$EXISTING_IMAGE")" in
  set)
    upsert_env_var AGLEDGER_IMAGE "${AGLEDGER_IMAGE}" "$ENV_FILE"
    RECONCILE_CHANGES+=("image registry: ${EXISTING_IMAGE:-agledger/agledger} → ${AGLEDGER_IMAGE}")
    ;;
  delete)
    delete_env_var AGLEDGER_IMAGE "$ENV_FILE"
    RECONCILE_CHANGES+=("image registry: ${EXISTING_IMAGE} → agledger/agledger")
    ;;
esac

# Pin the running stack to the digest that was pulled.
# compose images resolve `${AGLEDGER_IMAGE_PIN:-agledger/agledger:${AGLEDGER_VERSION}}`,
# so this makes every container run the exact bytes that arrived — not a
# floating tag that could be repointed afterwards.
#
# Pinning is right on every run. Calling the pin verified is only right on the
# run that verified it, so the line says which one this was: on a host without
# cosign the same install prints "Proceeding UNVERIFIED" a few steps earlier,
# and a reader skimming for the word — or a CI log scraper looking for evidence
# of supply-chain verification — must not find it here.
EXISTING_PIN=$(grep -E '^AGLEDGER_IMAGE_PIN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '[:space:]' || true)
if [[ -n "${AGLEDGER_IMAGE_PIN:-}" ]] && [[ "$EXISTING_PIN" != "$AGLEDGER_IMAGE_PIN" ]]; then
  upsert_env_var AGLEDGER_IMAGE_PIN "${AGLEDGER_IMAGE_PIN}" "$ENV_FILE"
  if [[ "${SIGNATURE_VERIFIED:-false}" == "true" ]]; then
    RECONCILE_CHANGES+=("pinned image to signature-verified digest: ${AGLEDGER_IMAGE_PIN##*@}")
  else
    RECONCILE_CHANGES+=("pinned image to UNVERIFIED digest (${UNVERIFIED_REASON:-not verified}): ${AGLEDGER_IMAGE_PIN##*@}")
  fi
elif [[ -z "${AGLEDGER_IMAGE_PIN:-}" ]] && [[ -n "$EXISTING_PIN" ]]; then
  # This run could not resolve a digest (the ref carries no usable RepoDigest,
  # either because the registry reported none or because no registry was
  # reached) but a pin from an earlier install lingers, naming a digest for a
  # version this run is not installing. Drop it rather than run those bytes.
  #
  # Reported, not silent. The pin is the only thing holding the stack to
  # signature-verified bytes, so dropping it back to a floating tag is a
  # security-relevant change to what the containers run, and RECONCILE_CHANGES
  # is what tells the run below to recreate them rather than keep --no-recreate.
  delete_env_var AGLEDGER_IMAGE_PIN "$ENV_FILE"
  RECONCILE_CHANGES+=("dropped the image digest pin (no digest resolved this run); containers now follow the ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION} tag")
  warn "No image digest could be resolved, so ${ENV_FILE} no longer pins one."
  warn "The stack follows the ${AGLEDGER_IMAGE}:${AGLEDGER_VERSION} tag, which can be repointed after verification."
fi

# --with-monitoring stands up the collector and Jaeger and points the operator
# at the Jaeger UI, so it has to turn tracing on too. Selecting the compose
# profile alone left the app exporting nothing and the UI permanently empty.
# Export is OTLP/HTTP, hence the collector's 4318 receiver.
BUNDLED_OTLP_ENDPOINT="http://otel-collector:4318"
OTLP_ENDPOINT_EFFECTIVE=""
GRAFANA_PASSWORD_STATE=keep
# `--with-monitoring` alone was the wrong gate. An install stood up with it
# before COMPOSE_PROFILES was persisted has the collector, Jaeger, Prometheus
# and Grafana running and nothing in .env selecting them, and the operator's
# re-run of plain `install.sh` is exactly how that .env gets repaired everywhere
# else. Without asking the containers, that run brought `up -d` with the profile
# unselected: all four stayed on the old image with the old port bindings while
# the banner reported a complete install. The containers are the only honest
# answer to "is monitoring part of this install", so ask them too.
MONITORING_ACTIVE=false
if [[ "$WITH_MONITORING" == true ]] || monitoring_containers_running; then
  MONITORING_ACTIVE=true
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

# Record the database mode in .env so the startup banner shows correctly.
#
# The old test was an unanchored `grep -q 'AGLEDGER_PG_BUNDLED='`, which matched
# the commented `# AGLEDGER_PG_BUNDLED=false` that every .env inherits from
# .env.example, so the line was never written on any install. get_env_value
# reads it the way compose does, which is to say it ignores comments.
#
# Not a RECONCILE_CHANGES entry on the bundled path: docker-compose.postgres.yml
# sets the same variable in the container's `environment:`, which wins over
# env_file, so nothing a container receives changes. On the external path there
# is no such overlay, so a stale `true` left by an earlier bundled install WOULD
# reach the container and make the banner lie; drop it there.
if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  if [[ -z "$(get_env_value AGLEDGER_PG_BUNDLED "$ENV_FILE")" ]]; then
    upsert_env_var AGLEDGER_PG_BUNDLED true "$ENV_FILE"
  fi
elif [[ -n "$(get_env_value AGLEDGER_PG_BUNDLED "$ENV_FILE")" ]]; then
  delete_env_var AGLEDGER_PG_BUNDLED "$ENV_FILE"
  RECONCILE_CHANGES+=("dropped AGLEDGER_PG_BUNDLED (this install uses an external database)")
fi

if [[ "$FRESH_ENV" != "true" ]] && [[ ${#RECONCILE_CHANGES[@]} -gt 0 ]]; then
  info "Reconciled existing .env (${#RECONCILE_CHANGES[@]} change(s)):"
  for change in "${RECONCILE_CHANGES[@]}"; do
    info "  - ${change}"
  done
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
  # SyntaxError for every DATABASE_URL, valid or not.
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

  # Migration privilege.
  #
  # The baseline migration installs the `agledger_block_audit_drop` event
  # trigger, which protects the audit chain, and CREATE EVENT TRIGGER is
  # superuser-only. A managed database hands you an owner role with CREATEDB
  # and not that, which is the default shape on Aurora, RDS, Cloud SQL and
  # Azure Database. Checked here, on a connection already open, rather than
  # after the pull and the container start: the failure was arriving as a raw
  # "permission denied to create event trigger" from inside a migration, with
  # the requirement stated in the AWS runbook only.
  info "Checking migration privileges..."
  MIGRATE_URL="${DATABASE_URL_MIGRATE:-${DATABASE_URL}}"
  PRIV_OUTPUT=$(docker run --rm \
    -e DATABASE_URL="${MIGRATE_URL}" \
    -e ALLOW_DB_WITHOUT_SSL="${ALLOW_DB_WITHOUT_SSL:-false}" \
    --entrypoint /nodejs/bin/node \
    "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    -e "
      const pg = require('pg');
      const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
      pool.query(\`SELECT current_user AS who,
               ${AUDIT_EVENT_TRIGGER_PREDICATE}
               AS can_event_trigger\`)
        .then(r => { console.log('PRIV=' + r.rows[0].can_event_trigger + ' USER=' + r.rows[0].who); pool.end(); })
        .catch(e => { console.error('PRIV_ERROR=' + e.message); process.exit(1); });
    " 2>&1) || true

  case "$(audit_event_trigger_verdict "$PRIV_OUTPUT")" in
  ok)
    info "Migration privileges: sufficient for the audit-chain event trigger"
    ;;
  refuse)
    # `|| true`: under `set -o pipefail`, `head -1` exits after the first line
    # and a large $PRIV_OUTPUT leaves sed writing to a closed pipe, so the
    # pipeline reports 141 and `set -e` kills the installer here, silently,
    # instead of printing the refusal this branch exists to print.
    PRIV_USER=$(echo "$PRIV_OUTPUT" | sed -n 's/.*USER=//p' | head -1 || true)
    error "The migration role '${PRIV_USER}' cannot create an event trigger, so migrations will fail."
    while IFS= read -r priv_line; do error "${priv_line}"; done < <(audit_event_trigger_remedy "${PRIV_USER}")
    error "To keep the running role least-privilege, put a superuser URL in DATABASE_URL_MIGRATE"
    error "(used for migrations only) and leave DATABASE_URL as the DML role. That role must be"
    error "named agledger_app, because the migration grants DML to that exact name and a role"
    error "called anything else gets no privileges on public; if your naming standard forbids it,"
    error "run GRANT agledger_app TO \"<your role>\" WITH INHERIT TRUE after migrating. It also"
    error "needs GRANT CREATE ON DATABASE <db>, which pg-boss uses to create its schema on first"
    error "boot. This installer checks both after migrating and names anything still missing."
    fatal "Grant the privilege and re-run. Nothing has been installed."
    ;;
  *)
    warn "Could not determine migration privileges: ${PRIV_OUTPUT}"
    warn "If migrations fail with 'permission denied to create event trigger', the role needs"
    warn "superuser (rds_superuser on RDS/Aurora, cloudsqlsuperuser on Cloud SQL, azure_pg_admin on Azure)."
    ;;
  esac
fi

# --- Config Gate ---
#
# `missing_prod_config` reports every production prerequisite the Server
# fail-fasts on, against the finished .env, before the pull. The refusal itself
# was always correct; where the operator found out was not. See the
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
# A failed pull is fatal only for images this host does not already have.
# Compose's default pull policy is `missing`, so the `up` and `run` steps below
# fetch nothing that is present, and a stack whose every image is in the local
# store runs identically whether this step succeeded or not. That is the enclave
# seeded by `docker load`, and the host whose registry is briefly down.
#
# What it must not do is pass silently on a missing image: the next step would
# then die inside a Compose pull error naming one image, several steps after the
# one that could have named all of them and said where to get them.
if "${COMPOSE[@]}" pull; then
  info "All images pulled"
else
  COMPOSE_IMAGES=()
  mapfile -t COMPOSE_IMAGES < <("${COMPOSE[@]}" config --images 2>/dev/null || true)
  if [[ ${#COMPOSE_IMAGES[@]} -eq 0 ]]; then
    fatal "Could not pull the stack's images, and could not read which images it runs. See the output above."
  fi
  MISSING_IMAGES=()
  for compose_image in "${COMPOSE_IMAGES[@]}"; do
    [[ -n "$compose_image" ]] || continue
    docker image inspect "$compose_image" >/dev/null 2>&1 || MISSING_IMAGES+=("$compose_image")
  done
  if [[ ${#MISSING_IMAGES[@]} -gt 0 ]]; then
    error "Could not pull, and these images the stack runs are not in this host's image store:"
    for compose_image in "${MISSING_IMAGES[@]}"; do
      error "  ${compose_image}"
    done
    error "Load each one ('docker load < image.tar.gz') or make the registry reachable, then re-run."
    fatal "Refusing to start a stack whose images are neither pullable nor present."
  fi
  warn "Could not pull. Every image this stack runs is already in this host's image store, so the"
  warn "run continues on those bytes; nothing here compared them against a registry."
fi

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

# --- Runtime Role Gate ---
#
# Everything after this point runs as the role in DATABASE_URL, and two ways of
# provisioning that role leave it unable to serve: the migration grants DML to
# the literal name `agledger_app`, so a differently-named non-owner role gets
# nothing on public, and pg-boss creates its own schema on first start, which
# needs CREATE on the database. Neither is visible in the migration output.
#
# What the operator saw instead was the next two steps failing on whatever
# table or object they touched first ("permission denied for table api_keys",
# "permission denied for database agledger") and then `API did not become
# healthy`, with the run ending before the preflight step that diagnoses
# exactly this. Preflight has to run BEFORE the health gate the condition it
# reports prevents from opening, not after it.
#
# Only the two checks that decide whether the API can boot: the full run is
# still at the end of the install, against a started stack, where the rest of
# the checks have something to look at.
step "Checking runtime role privileges"

# --no-deps because agledger-api depends on agledger-migrate completing
# successfully, and the migration that just ran was a `run --rm`, which leaves
# no exited container for compose to see. Without the flag it re-runs the whole
# migration to satisfy the dependency. On the bundled-Postgres path the database
# is already up from "Starting data stores"; on the external path there is no
# dependency to start at all.
if ! "${COMPOSE[@]}" run --rm --no-deps --entrypoint /nodejs/bin/node agledger-api \
    dist/scripts/preflight.js --only=runtime-role,pgboss; then
  echo ""
  error "The role in DATABASE_URL is not ready to serve. The report above is the diagnosis: a"
  error "privilege failure names the role and the exact grant to run; a connection failure names"
  error "what the connection attempt returned, which no grant will fix."
  error "Migrations are already applied, so re-running this installer after fixing it is safe."
  fatal "Fix what the check reported and re-run."
fi

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

  # Build DATABASE_URL via a temp env file to avoid exposing password in ps output.
  #
  # Normalized rather than copied. `--env-file` is not a dotenv parser: it splits
  # on the first `=` and takes the rest of the line literally, quotes included.
  # An operator who quoted a multi-parameter URL -- which they must, for the
  # other readers -- handed init `"postgresql://...` as a hostname, and the run
  # ended "installed, but NOT usable (no platform API key)" with the stack
  # healthy, because compose's own parser had read the same file correctly.
  init_env=$(mktemp)
  dotenv_normalize_file "$ENV_FILE" "$init_env"

  # If using bundled postgres and no DATABASE_URL is set, construct one.
  # bundled_database_url applies the same `:-agledger` defaults the compose
  # files apply, which this `docker run` does not get, and refuses to build a
  # URL with no password rather than handing init one that cannot authenticate.
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -z "$(get_env_value DATABASE_URL "$ENV_FILE")" ]]; then
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
    # An empty `DATABASE_URL=` normalized out of .env would otherwise sit above
    # the one being added. Docker takes the last, but two assignments of the
    # engine's most load-bearing variable in one file is a trap for whoever
    # reads it next.
    sedi '/^DATABASE_URL=$/d' "$init_env"
    echo "DATABASE_URL=${bundled_url}" >> "$init_env"
  fi
  chmod 600 "$init_env"

  init_output=$(docker run --rm \
    --env-file "$init_env" \
    --network "${compose_network}" \
    "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
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
    # Filter by variable name, not by guessing at substrings: the old
    # `password|secret` pattern matched neither `VAULT_SIGNING_KEY=` nor a
    # `DATABASE_URL=` whose password is just a random string.
    echo "$init_output" | grep -v -E '^[A-Za-z0-9_]*(KEY|SECRET|PASSWORD|TOKEN|DATABASE_URL)[A-Za-z0-9_]*=' || true
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
# every reinstall produces duplicate keys and banner confusion.
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
# re-run-per-key loop.
#
# The wait's verdict is not the whole answer, which is why the container states
# are asked for as well: `--wait` is satisfied by a container that is merely
# running whenever the service declares no healthcheck, and a crash-looping
# container is running between restarts.
if ! "${COMPOSE[@]}" up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" agledger-api --wait \
   || ! all_compose_services_up agledger-api; then
  error "Failed to start API."
  echo ""
  # Which of the two halves of the condition above failed decides what is worth
  # printing. A container that is restarting, exited, unhealthy or absent is
  # named by the reporter, with its own log tail. When every container reports
  # up it is the wait itself that timed out, the reporter has nothing to name,
  # and the tail is the only thing that explains it.
  if all_compose_services_up agledger-api; then
    "${COMPOSE[@]}" logs --tail "${COMPOSE_FAIL_LOG_LINES}" --no-log-prefix agledger-api 2>&1 | sed 's/^/    /' || true
  else
    report_failed_compose_services agledger-api || true
  fi
  fatal "API did not become healthy."
fi

# MONITORING_ACTIVE, not WITH_MONITORING: a re-run without the flag on a host
# whose monitoring containers are up still has to bring them with it, or they
# keep running on the previous image while everything else moves.
#
# Same reasoning as the API's own `up -d --wait` above: a bare failure here
# reports "container is unhealthy" with no service name and no log, and falls
# straight to the generic cleanup trap under `set -e`. Name what this call
# starts and print each one's tail on failure, the same as the API does for
# itself.
if [[ "$MONITORING_ACTIVE" == true ]]; then
  SECOND_UP_SERVICES=(agledger-worker otel-collector jaeger prometheus grafana)
  # Before the wait, not after: a service whose mounted config file changed is
  # still running the old one, and `up -d` will not notice. Restarting first is
  # what puts the check below over the configuration that is on disk, so a
  # config that does not load fails this install rather than the next one.
  restart_mounted_config_services
  if ! "${COMPOSE[@]}" --profile monitoring up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" --wait \
     || ! all_compose_services_up "${SECOND_UP_SERVICES[@]}"; then
    error "Failed to start the worker and/or the monitoring stack:"
    echo ""
    if all_compose_services_up "${SECOND_UP_SERVICES[@]}"; then
      error "Every container reports running, so the wait itself timed out rather than a"
      error "container failing. Re-check with: docker compose ps"
    else
      report_failed_compose_services "${SECOND_UP_SERVICES[@]}" || true
    fi
    fatal "Worker and/or monitoring services did not become healthy."
  fi
else
  if ! "${COMPOSE[@]}" up -d "${UP_FLAGS[@]+"${UP_FLAGS[@]}"}" --wait \
     || ! all_compose_services_up agledger-worker; then
    error "Failed to start the worker."
    echo ""
    if all_compose_services_up agledger-worker; then
      "${COMPOSE[@]}" logs --tail "${COMPOSE_FAIL_LOG_LINES}" --no-log-prefix agledger-worker 2>&1 | sed 's/^/    /' || true
    else
      report_failed_compose_services agledger-worker || true
    fi
    fatal "Worker did not become healthy."
  fi
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
# records already written, so the operator must see it, and be warned if it's still the
# localhost eval default, before notarizing records they intend to keep. A fresh Compose
# install signs the chain under iss: http://localhost:3001 by default.
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
# /health/ready rather than /health: the one an operator opens should be the one
# that answers the question they are asking, which is whether the Server can
# serve. /health is a static 200 and says nothing about the database.
echo -e "  ${BOLD}Health:${NC}        ${API_URL}/health/ready"
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
# up the scrollback.
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
