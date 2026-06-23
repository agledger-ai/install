#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Remote Deploy Orchestrator (agl-deploy.sh)
# =============================================================================
# A thin, client-side SSH wrapper that deploys and operates an AGLedger Server
# on a remote host. It opens one SSH connection per operation and drives the
# pinned, signed installer (github.com/agledger-ai/install) and its on-target
# scripts (install.sh / upgrade.sh / uninstall.sh / lib-compose.sh) — it does
# NOT reimplement cosign verification, key minting, secret generation,
# migrations, or health gating. The Server's own scripts remain the source of
# truth; this just carries them over SSH.
#
# POSITIONING: deploys and operates a single-node AGLedger — the Developer
# Edition (Docker Compose on Docker CE, bundled PostgreSQL): free and
# production-ready. The Compose stack binds the API to 127.0.0.1:3001 (loopback
# only), so you reach it over an SSH tunnel (`tunnel`), optionally through a
# bastion (`-J`); for production, set AGLEDGER_EXTERNAL_URL and front the API
# with TLS. Enterprise (Kubernetes/Helm, external database) is the path for
# multi-node scale and HA — https://agledger.ai/docs/install.
#
# Requirements:
#   Local : ssh, bash, base64.
#   Remote: Ubuntu 22.04+/Debian over SSH with a passwordless-sudo user (or
#           root). `bootstrap` installs Docker, the compose plugin, jq, curl,
#           openssl, git, and cosign; `install` runs it for you.
#
# Quick start:
#   ./agl-deploy.sh -H agl@HOST -i ~/.ssh/agl install
#   ./agl-deploy.sh -H agl@HOST -i ~/.ssh/agl tunnel    # then curl localhost:3001/health
# =============================================================================

# --- Inline helpers (kept in lockstep with deploy/scripts/lib-compose.sh) ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

ts() { date '+%Y-%m-%d %H:%M:%S'; }
info()  { echo -e "$(ts) ${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "$(ts) ${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "$(ts) ${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n$(ts) ${BLUE}[STEP]${NC}  ${BOLD}$*${NC}"; }
fatal() { error "$*"; exit 1; }

# base64-encode a value for safe transport as an ssh remote-command argument.
# ssh space-joins the remote command and the remote shell re-parses it, so any
# value carrying shell metacharacters would break; base64 output never does.
b64() { printf '%s' "${1-}" | base64 | tr -d '\n'; }

# The decoder prepended to every remote script (quoted heredocs can't expand a
# local function, so it ships as text). The $1 is literal-on-purpose — it's the
# remote shell's positional, expanded there, not here.
# shellcheck disable=SC2016
REMOTE_PREAMBLE='set -euo pipefail; d64() { printf "%s" "$1" | base64 -d; }'

REPO_URL="https://github.com/agledger-ai/install.git"

# --- Defaults (env-var equivalents, overridable by flags) --------------------

AGL_SSH_TARGET="${AGL_SSH_TARGET:-}"
AGL_SSH_KEY="${AGL_SSH_KEY:-}"
AGL_SSH_PORT="${AGL_SSH_PORT:-22}"
AGL_SSH_JUMP="${AGL_SSH_JUMP:-}"
AGL_VERSION="${AGL_VERSION:-}"
AGL_REPO_TAG="${AGL_REPO_TAG:-}"
AGL_REMOTE_DIR="${AGL_REMOTE_DIR:-agledger-install}"
AGL_EXTERNAL_DB_URL="${AGL_EXTERNAL_DB_URL:-}"
WITH_MONITORING=false
SKIP_VERIFY=false
ASSUME_YES=false
LOCAL_PORT=3001
REMOTE_PORT=3001

usage() {
  cat <<'EOF'
AGLedger — Remote Deploy Orchestrator

Usage:
  ./agl-deploy.sh [options] <command> [command-args]

Commands:
  bootstrap            Install Docker + jq/curl/openssl/git/cosign on the remote
  install              bootstrap -> clone pinned installer -> run it -> print key + health
  upgrade VERSION      Upgrade the remote Server to VERSION (backs up first)
  status               Container status + API health
  health               Probe /health, /health/ready, /v1/verification-keys
  key                  Reprint the saved platform admin key from the remote .env
  logs [SERVICE]       Follow compose logs (e.g. logs agledger-api); all services if omitted
  tunnel               Hold an SSH tunnel: localhost:3001 -> remote API (Ctrl-C to close)
  shell                Interactive SSH session on the remote
  uninstall [--purge]  Stop & remove the stack; --purge also deletes the DB volume

Options (env var equivalent in parens):
  -H, --host USER@HOST   (AGL_SSH_TARGET)       SSH target (required)
  -i, --identity FILE    (AGL_SSH_KEY)          SSH private key
  -p, --port PORT        (AGL_SSH_PORT)         SSH port (default 22)
  -J, --jump USER@HOST   (AGL_SSH_JUMP)         SSH bastion (ProxyJump) to reach the target
  -V, --version X.Y.Z    (AGL_VERSION)          AGLedger version (default: installer resolves latest)
      --repo-tag vX.Y.Z  (AGL_REPO_TAG)         install-repo git tag (default v<version>)
      --dir PATH         (AGL_REMOTE_DIR)       remote install dir (default agledger-install)
      --with-monitoring                         enable the Jaeger/Prometheus/Grafana profile
      --skip-verify                             skip cosign verification (DEV ONLY)
  -y, --yes                                     don't prompt for confirmation
  -h, --help                                    show this help

Deploys the Developer Edition (Compose on Docker CE, bundled PostgreSQL) — free
and production-ready. Enterprise (Kubernetes/Helm, external database) is the
multi-node scale/HA tier: https://agledger.ai/docs/install
EOF
}

# --- Argument parsing --------------------------------------------------------

COMMAND=""
COMMAND_ARGS=()

while [[ $# -gt 0 ]]; do
  # Global options precede the command; once the command is set, everything
  # else (including dashed args like `uninstall --purge`) is a command arg.
  if [[ -n "$COMMAND" ]]; then COMMAND_ARGS+=("$1"); shift; continue; fi
  case "$1" in
    -H|--host)       AGL_SSH_TARGET="$2"; shift 2 ;;
    -i|--identity)   AGL_SSH_KEY="$2"; shift 2 ;;
    -p|--port)       AGL_SSH_PORT="$2"; shift 2 ;;
    -J|--jump)       AGL_SSH_JUMP="$2"; shift 2 ;;
    -V|--version)    AGL_VERSION="$2"; shift 2 ;;
    --repo-tag)      AGL_REPO_TAG="$2"; shift 2 ;;
    --dir)           AGL_REMOTE_DIR="$2"; shift 2 ;;
    --external-db)   AGL_EXTERNAL_DB_URL="$2"; shift 2 ;;
    --with-monitoring) WITH_MONITORING=true; shift ;;
    --skip-verify)   SKIP_VERIFY=true; shift ;;
    -y|--yes)        ASSUME_YES=true; shift ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; break ;;
    -*)              fatal "Unknown option: $1 (use --help)" ;;
    *)
      if [[ -z "$COMMAND" ]]; then
        COMMAND="$1"
      else
        COMMAND_ARGS+=("$1")
      fi
      shift
      ;;
  esac
done
# Anything after `--` is a command arg.
while [[ $# -gt 0 ]]; do
  if [[ -z "$COMMAND" ]]; then COMMAND="$1"; else COMMAND_ARGS+=("$1"); fi
  shift
done

[[ -n "$COMMAND" ]] || { usage; exit 1; }

# --- Input validation (these values flow into remote command lines) ----------

if [[ -n "$AGL_VERSION" && ! "$AGL_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
  fatal "Invalid --version '${AGL_VERSION}' (expected X.Y.Z)"
fi
if [[ -n "$AGL_REPO_TAG" && ! "$AGL_REPO_TAG" =~ ^v?[0-9A-Za-z][0-9A-Za-z._-]*$ ]]; then
  fatal "Invalid --repo-tag '${AGL_REPO_TAG}'"
fi
if [[ ! "$AGL_REMOTE_DIR" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ || "$AGL_REMOTE_DIR" == *..* ]]; then
  fatal "Invalid --dir '${AGL_REMOTE_DIR}' (relative path, no '..')"
fi
if [[ ! "$AGL_SSH_PORT" =~ ^[0-9]+$ ]]; then
  fatal "Invalid --port '${AGL_SSH_PORT}'"
fi

# Resolve the repo tag to clone: explicit --repo-tag wins; else v<version>; else
# the default branch (installer then resolves the latest released image).
RESOLVED_TAG="$AGL_REPO_TAG"
if [[ -z "$RESOLVED_TAG" && -n "$AGL_VERSION" ]]; then
  RESOLVED_TAG="v${AGL_VERSION}"
fi

# --- SSH plumbing ------------------------------------------------------------

SSH_OPTS=()
build_ssh_opts() {
  SSH_OPTS=(-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
  [[ -n "$AGL_SSH_KEY" ]] && SSH_OPTS+=(-i "$AGL_SSH_KEY" -o IdentitiesOnly=yes)
  [[ "$AGL_SSH_PORT" != "22" ]] && SSH_OPTS+=(-p "$AGL_SSH_PORT")
  [[ -n "$AGL_SSH_JUMP" ]] && SSH_OPTS+=(-J "$AGL_SSH_JUMP")
  return 0  # never let a false trailing && propagate under `set -e`
}

require_target() {
  [[ -n "$AGL_SSH_TARGET" ]] || fatal "No SSH target. Pass -H user@host or set AGL_SSH_TARGET."
  build_ssh_opts
}

# Run a remote script (fed on stdin via `bash -s`) with base64-encoded
# positional args. The remote stdin IS the script, so any remote command that
# itself reads stdin MUST be given its own (e.g. piped) input.
remote_run() {
  local script="$1"; shift
  local -a args=()
  local a
  for a in "$@"; do args+=("$(b64 "$a")"); done
  # SC2087 off by design: ${REMOTE_PREAMBLE}/${script} MUST expand client-side —
  # that's how the script body is injected. Their values aren't rescanned, and
  # all data flows in as base64 positional args, so nothing else interpolates.
  # shellcheck disable=SC2087
  ssh -o BatchMode=yes "${SSH_OPTS[@]}" "$AGL_SSH_TARGET" bash -s -- "${args[@]}" <<AGLR
${REMOTE_PREAMBLE}
${script}
AGLR
}

confirm() {
  $ASSUME_YES && return 0
  local reply
  read -rp "$1 (y/N) " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Commands ----------------------------------------------------------------

# Idempotent prereq install: installs ONLY what's missing (Docker CE via the
# official convenience script, apt packages, cosign from its GitHub release).
# Escalates with sudo only when there's actually something to install, and
# fails loudly with the gap list if root is needed but unavailable — it never
# hangs on a hidden password prompt.
bootstrap_script() {
  cat <<'AGLR'
have() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

MISSING_PKGS=""
for p in curl jq openssl git; do have "$p" || MISSING_PKGS="$MISSING_PKGS $p"; done
have update-ca-certificates || MISSING_PKGS="$MISSING_PKGS ca-certificates"
NEED_DOCKER=0; have docker || NEED_DOCKER=1
NEED_COSIGN=0; have cosign  || NEED_COSIGN=1
NEED_GROUP=0
if [ "$NEED_DOCKER" = 0 ] && [ "$(id -u)" -ne 0 ] && ! id -nG | tr ' ' '\n' | grep -qx docker; then
  NEED_GROUP=1   # docker present but this user can't reach it without sudo
fi

if [ -z "$MISSING_PKGS" ] && [ "$NEED_DOCKER" = 0 ] && [ "$NEED_COSIGN" = 0 ] && [ "$NEED_GROUP" = 0 ]; then
  echo "bootstrap: all prerequisites already present — nothing to do"
  exit 0
fi

# Root is required for everything below; refuse early (don't block on a prompt).
if [ "$(id -u)" -ne 0 ] && ! $SUDO -n true 2>/dev/null; then
  echo "ERROR: prerequisites are missing but this account has no passwordless sudo." >&2
  echo "  missing packages:${MISSING_PKGS:- none}" >&2
  echo "  docker: $([ $NEED_DOCKER = 1 ] && echo MISSING || echo ok); cosign: $([ $NEED_COSIGN = 1 ] && echo MISSING || echo ok); docker-group: $([ $NEED_GROUP = 1 ] && echo needed || echo ok)" >&2
  echo "  Install these as root (or from a passwordless-sudo account) and re-run." >&2
  exit 1
fi

if [ -n "$MISSING_PKGS" ] || [ "$NEED_DOCKER" = 1 ]; then
  have apt-get || { echo "ERROR: auto-install supports Debian/Ubuntu (apt) only; install$MISSING_PKGS + docker manually" >&2; exit 1; }
fi
if [ -n "$MISSING_PKGS" ]; then
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update -qq
  # shellcheck disable=SC2086
  $SUDO apt-get install -y -qq $MISSING_PKGS
fi
if [ "$NEED_DOCKER" = 1 ]; then
  # Docker CE only — the Developer Edition substrate. If get.docker.com doesn't
  # support the release yet, fail loudly pointing at the CE install rather than
  # pulling in a different (distro-packaged) Docker.
  curl -fsSL https://get.docker.com | $SUDO sh || true
  have docker || { echo "ERROR: could not install Docker CE. Install Docker Engine (CE) — https://docs.docker.com/engine/install/ — and re-run." >&2; exit 1; }
  $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  NEED_GROUP=1
fi
# Let the (non-root) login user reach docker without sudo on the NEXT session.
if [ "$NEED_GROUP" = 1 ] && [ "$(id -u)" -ne 0 ]; then $SUDO usermod -aG docker "$(id -un)" || true; fi
if [ "$NEED_COSIGN" = 1 ]; then
  case "$(uname -m)" in
    x86_64|amd64) COSARCH=amd64 ;;
    aarch64|arm64) COSARCH=arm64 ;;
    *) echo "WARN: no cosign build for $(uname -m); image verification will be skipped" >&2; COSARCH="" ;;
  esac
  if [ -n "$COSARCH" ]; then
    TMP="$(mktemp)"
    curl -fsSL -o "$TMP" "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${COSARCH}"
    $SUDO install -m 0755 "$TMP" /usr/local/bin/cosign
    rm -f "$TMP"
  fi
fi
echo "bootstrap: docker=$(docker --version 2>/dev/null || echo missing) cosign=$(cosign version 2>/dev/null | head -1 || echo missing)"
AGLR
}

cmd_bootstrap() {
  require_target
  step "Installing prerequisites on ${AGL_SSH_TARGET}"
  remote_run "$(bootstrap_script)"
  info "Prerequisites ready"
}

cmd_install() {
  require_target
  if [[ -n "$AGL_EXTERNAL_DB_URL" ]]; then
    fatal "--external-db is not supported by the remote wrapper (its secret/.env ordering is subtle).
       An external database is an Enterprise feature; run that path directly on the target:
         ssh ${AGL_SSH_TARGET} 'cd ${AGL_REMOTE_DIR} && DATABASE_URL=... scripts/install.sh --external-db --non-interactive'
       The wrapper deploys the Developer Edition (bundled PostgreSQL)."
  fi

  step "Installing prerequisites on ${AGL_SSH_TARGET}"
  remote_run "$(bootstrap_script)"

  # Separate SSH session so the docker-group membership added by bootstrap is
  # active for the installer's (non-sudo) docker calls.
  step "Cloning installer and running it on ${AGL_SSH_TARGET}"
  local install_script
  install_script=$(cat <<'AGLR'
VERSION="$(d64 "$1")"; REPO_TAG="$(d64 "$2")"; REMOTE_DIR="$(d64 "$3")"
REPO_URL="$(d64 "$4")"; WITH_MON="$(d64 "$5")"; SKIP_VERIFY="$(d64 "$6")"
if [ -d "$REMOTE_DIR/.git" ]; then
  git -C "$REMOTE_DIR" fetch --tags --quiet
  [ -n "$REPO_TAG" ] && git -C "$REMOTE_DIR" -c advice.detachedHead=false checkout --quiet "$REPO_TAG"
elif [ -n "$REPO_TAG" ]; then
  git clone --quiet --depth 1 --branch "$REPO_TAG" "$REPO_URL" "$REMOTE_DIR"
else
  git clone --quiet --depth 1 "$REPO_URL" "$REMOTE_DIR"
fi
cd "$REMOTE_DIR"
ARGS=(--non-interactive)
[ -n "$VERSION" ] && ARGS+=(--version "$VERSION")
[ "$WITH_MON" = "1" ] && ARGS+=(--with-monitoring)
[ "$SKIP_VERIFY" = "1" ] && ARGS+=(--skip-verify)
scripts/install.sh "${ARGS[@]}" </dev/null
AGLR
)
  remote_run "$install_script" \
    "$AGL_VERSION" "$RESOLVED_TAG" "$AGL_REMOTE_DIR" "$REPO_URL" \
    "$([[ $WITH_MONITORING == true ]] && echo 1 || echo 0)" \
    "$([[ $SKIP_VERIFY == true ]] && echo 1 || echo 0)"

  info "Install complete. Reprinting the platform key + health below:"
  cmd_key || true
  cmd_health || true
}

cmd_upgrade() {
  require_target
  local version="${COMMAND_ARGS[0]:-}"
  [[ -n "$version" ]] || fatal "upgrade needs a version: agl-deploy.sh ... upgrade 1.0.3"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]] || fatal "Invalid version '${version}'"
  confirm "Upgrade ${AGL_SSH_TARGET} to ${version} (a backup is taken first)?" || { warn "Aborted."; return 1; }
  step "Upgrading ${AGL_SSH_TARGET} to ${version}"
  local script
  script=$(cat <<'AGLR'
VERSION="$(d64 "$1")"; REMOTE_DIR="$(d64 "$2")"
cd "$REMOTE_DIR"
git fetch --tags --quiet || true
git -c advice.detachedHead=false checkout --quiet "v${VERSION}" 2>/dev/null || true
# upgrade.sh prompts on its own stdin; give it an explicit "y" so it never
# reads from the bash -s script stream.
printf 'y\n' | scripts/upgrade.sh "$VERSION"
AGLR
)
  remote_run "$script" "$version" "$AGL_REMOTE_DIR"
  info "Upgrade complete"
}

cmd_status() {
  require_target
  step "Status of ${AGL_SSH_TARGET}"
  local script
  script=$(cat <<'AGLR'
REMOTE_DIR="$(d64 "$1")"
cd "$REMOTE_DIR"
# Reuse the installer's own compose-file resolution rather than duplicating it.
source scripts/lib-compose.sh
load_env 2>/dev/null || true
detect_db_mode 2>/dev/null || true
build_compose_cmd
"${COMPOSE[@]}" ps
AGLR
)
  remote_run "$script" "$AGL_REMOTE_DIR"
  cmd_health || true
}

cmd_health() {
  require_target
  step "Health probes on ${AGL_SSH_TARGET}"
  local script
  script=$(cat <<'AGLR'
for ep in /health /health/ready /v1/verification-keys; do
  printf '%s -> ' "$ep"
  curl -fsS --max-time 10 "http://localhost:3001${ep}" || echo "(unreachable)"
  echo
done
AGLR
)
  remote_run "$script"
}

cmd_key() {
  require_target
  step "Platform admin key from ${AGL_SSH_TARGET}"
  local script
  script=$(cat <<'AGLR'
REMOTE_DIR="$(d64 "$1")"
KEY="$(grep -E '^PLATFORM_API_KEY=agl_plt_' "$REMOTE_DIR/compose/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
if [ -n "$KEY" ]; then echo "$KEY"; else echo "(no PLATFORM_API_KEY found in $REMOTE_DIR/compose/.env)" >&2; exit 1; fi
AGLR
)
  remote_run "$script" "$AGL_REMOTE_DIR"
}

cmd_logs() {
  require_target
  local service="${COMMAND_ARGS[0]:-}"
  if [[ -n "$service" && ! "$service" =~ ^[A-Za-z0-9_-]+$ ]]; then
    fatal "Invalid service name '${service}'"
  fi
  step "Logs from ${AGL_SSH_TARGET} (Ctrl-C to stop)"
  local script
  script=$(cat <<'AGLR'
REMOTE_DIR="$(d64 "$1")"; SERVICE="$(d64 "$2")"
cd "$REMOTE_DIR"
source scripts/lib-compose.sh
load_env 2>/dev/null || true
detect_db_mode 2>/dev/null || true
build_compose_cmd
if [ -n "$SERVICE" ]; then "${COMPOSE[@]}" logs -f "$SERVICE"; else "${COMPOSE[@]}" logs -f; fi
AGLR
)
  # -t so Ctrl-C reaches the remote `logs -f`.
  build_ssh_opts
  local -a args=("$(b64 "$AGL_REMOTE_DIR")" "$(b64 "$service")")
  # shellcheck disable=SC2087  # client-side body injection — see remote_run
  ssh -t "${SSH_OPTS[@]}" "$AGL_SSH_TARGET" bash -s -- "${args[@]}" <<AGLR
${REMOTE_PREAMBLE}
${script}
AGLR
}

cmd_tunnel() {
  require_target
  step "Tunnel: localhost:${LOCAL_PORT} -> ${AGL_SSH_TARGET} :${REMOTE_PORT} (Ctrl-C to close)"
  info "In another shell: curl http://localhost:${LOCAL_PORT}/health"
  exec ssh -N -L "${LOCAL_PORT}:localhost:${REMOTE_PORT}" "${SSH_OPTS[@]}" "$AGL_SSH_TARGET"
}

cmd_shell() {
  require_target
  step "Opening a shell on ${AGL_SSH_TARGET}"
  exec ssh -t "${SSH_OPTS[@]}" "$AGL_SSH_TARGET"
}

cmd_uninstall() {
  require_target
  local purge=false
  [[ "${COMMAND_ARGS[0]:-}" == "--purge" ]] && purge=true
  local what="Stop & remove the stack on ${AGL_SSH_TARGET}"
  $purge && what="$what AND DELETE THE DATABASE VOLUME (irreversible)"
  confirm "${what}?" || { warn "Aborted."; return 1; }
  step "Uninstalling on ${AGL_SSH_TARGET}"
  local script
  script=$(cat <<'AGLR'
REMOTE_DIR="$(d64 "$1")"; PURGE="$(d64 "$2")"
cd "$REMOTE_DIR"
if [ "$PURGE" = "1" ]; then scripts/uninstall.sh --non-interactive --purge; else scripts/uninstall.sh --non-interactive; fi
AGLR
)
  remote_run "$script" "$AGL_REMOTE_DIR" "$($purge && echo 1 || echo 0)"
  info "Uninstall complete"
}

# --- Dispatch ----------------------------------------------------------------

case "$COMMAND" in
  bootstrap) cmd_bootstrap ;;
  install)   cmd_install ;;
  upgrade)   cmd_upgrade ;;
  status)    cmd_status ;;
  health)    cmd_health ;;
  key)       cmd_key ;;
  logs)      cmd_logs ;;
  tunnel)    cmd_tunnel ;;
  shell)     cmd_shell ;;
  uninstall) cmd_uninstall ;;
  *)         fatal "Unknown command: ${COMMAND} (use --help)" ;;
esac
