#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Upgrade Script
# =============================================================================
# Usage:
#   ./scripts/upgrade.sh 1.3.0
#   ./scripts/upgrade.sh 1.3.0 --skip-backup
# =============================================================================

# --- Shared Helpers ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"

# Set once this run stops the worker for the migration. Everything above that
# point leaves the install exactly as it found it; everything below does not,
# and telling an operator whose migration just failed that "your previous
# version should still be running" is wrong in the one direction that matters:
# the worker is down, so nothing is processing jobs, dispatching webhooks or
# sweeping deadlines, and the message they were given says to do nothing.
#
# The latch answers "did this run stop the worker", which is NOT the same
# question as "is the worker down now", and the trap needs the second one. The
# restart below brings the worker back and the run can still fail after it: the
# container-state gate fails the upgrade when ANY service is down, so a broken
# otel-collector config exits 1 with the worker running and healthy, and a
# Ctrl-C anywhere past the restart does the same. Reported off the latch alone,
# every one of those tells an operator mid-incident that the write path is dead
# on a stack that is serving, which is the one thing this message must never
# say. The latch stays as the gate on whether the question is worth asking at
# all; what is printed comes from worker_state_now.
WORKER_STOPPED=false

# What the worker is doing at the moment the trap fires: `up`, `down` or
# `unknown`.
#
# Observed, not tracked. Clearing the latch at each point the worker comes back
# would fail open the day someone adds an early exit below the restart, and
# would be re-derived wrongly the first time a restart half-succeeds; asking
# Docker cannot go stale.
#
# `up` means here exactly what it means to the restart gate this script already
# runs, because it is the same predicate: a container that exists, is running,
# is not unhealthy, and is not crash-looping between samples (the gate's
# restart-counter check, against the baseline this run took). A second
# definition of "up" living in the trap would drift from the one the upgrade
# enforces, and the trap is read at the moment the two disagreeing is most
# expensive.
#
# Docker being unreachable is its own answer rather than a verdict.
# failed_compose_services reads a `docker ps` it cannot run as "no container was
# created", which is indistinguishable from a worker that never came back, so
# reachability is probed first and an unanswerable daemon reports `unknown`.
# `unknown` is then reported as down-until-proven-otherwise: a false alarm the
# text admits to is recoverable, a missed one is not.
#
# A container inside its healthcheck start_period is `unknown`, not `up`.
# failed_compose_services deliberately lets `(health: starting)` pass, because
# the restart gate only consults it after `up -d --wait` has already waited the
# start_period out. The trap has no such guarantee: it is reached seconds after
# the container was created, which is exactly when a worker that is going to
# fail its own readiness still reads `running`. Calling that `up` would tell an
# operator nothing needs restarting and withhold the command to do it.
worker_state_probe() {
  if ! command -v docker >/dev/null 2>&1 || ! docker ps --quiet >/dev/null 2>&1; then
    printf 'unknown\n'
    return 0
  fi
  local project status
  project="$(compose_project_name)"
  status="$(docker ps -a \
    --filter "label=com.docker.compose.project=${project}" \
    --filter "label=com.docker.compose.service=agledger-worker" \
    --filter "label=com.docker.compose.oneoff=False" \
    --format '{{.Status}}' 2>/dev/null || true)"
  if [[ "$status" == *"(health: starting)"* ]]; then
    printf 'unknown\n'
    return 0
  fi
  if all_compose_services_up agledger-worker; then
    printf 'up\n'
  else
    printf 'down\n'
  fi
}

# The probe runs on a leash. It is called from the EXIT trap, and bash will not
# run the INT trap while the EXIT trap is running, so a `docker ps` against a
# wedged daemon would hang the trap with no recovery text on screen and no way
# to Ctrl-C out of it: the one outcome worse than the false alarm this whole
# change exists to remove. A probe that overruns is killed and answers
# `unknown`, which prints the same down-until-proven-otherwise text.
WORKER_PROBE_TIMEOUT_DECISECONDS=50
worker_state_now() {
  local out_file pid waited=0
  out_file="$(mktemp 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  worker_state_probe >"$out_file" 2>/dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && (( waited < WORKER_PROBE_TIMEOUT_DECISECONDS )); do
    sleep 0.1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    rm -f "$out_file"
    printf 'unknown\n'
    return 0
  fi
  wait "$pid" 2>/dev/null || true
  local answer
  answer="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
  printf '%s\n' "${answer:-unknown}"
}

worker_restart_hint() {
  error "Finish or abandon the upgrade, then bring it back with either:"
  error "  ./scripts/upgrade.sh ${TARGET_VERSION}          # re-run; applied migrations are skipped"
  error "  (cd ${COMPOSE_DIR} && docker compose up -d)   # restart on the version .env names"
}

cleanup() {
  local exit_code=$?
  local worker_now=untouched
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    if [[ "$WORKER_STOPPED" == true ]]; then
      worker_now="$(worker_state_now)"
    fi
    case "$worker_now" in
      untouched)
        error "Upgrade failed. Nothing was stopped, so your previous version is still running."
        ;;
      up)
        error "Upgrade failed after the worker was stopped for the migration, and the worker is"
        error "back UP: it is running and healthy, so jobs, webhook deliveries and deadline"
        error "sweeps are being processed. Nothing has to be restarted to get the worker back;"
        error "the ps command below is what answers for the rest of the stack."
        error "The install is not untouched, though: this run got past the worker stop, so it is"
        error "part-upgraded. Fix what is reported above and finish it:"
        error "  ./scripts/upgrade.sh ${TARGET_VERSION}          # re-run; applied migrations are skipped"
        ;;
      unknown)
        error "Upgrade failed AFTER the worker was stopped for the migration, and Docker could"
        error "not be asked whether it came back. Treat the worker as DOWN until the ps command"
        error "below says otherwise: while it is down there are no jobs, no webhook deliveries"
        error "and no deadline sweeps."
        worker_restart_hint
        ;;
      *)
        error "Upgrade failed AFTER the worker was stopped for the migration."
        error "The worker is DOWN: no jobs, no webhook deliveries, no deadline sweeps"
        error "until it is back. Whether the API is still serving depends on how far this"
        error "run got; the ps command below answers that."
        worker_restart_hint
        ;;
    esac
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
      echo ""
      echo "Environment:"
      echo "  AGLEDGER_REQUIRE_VERIFY=true   Refuse to upgrade when the image cannot be verified."
      echo "                       Without it an upgrade proceeds unverified (with a warning) on a"
      echo "                       host that has no cosign."
      echo "  AGLEDGER_VERIFY_BUNDLE_DIR     Verify offline, from an unpacked"
      echo "                       agledger-<version>-offline-verification.tar.gz. See air-gap/README.md."
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

# --- Compose version floor ---
# The compose file this upgrade is about to run declares an inline
# `configs.content`, which Compose below 2.23.1 fails to parse rather than
# ignore. Refuse before anything is stopped: an upgrade that gets as far as
# stopping the worker and then cannot run `compose up` leaves the stack down.
COMPOSE_STATE="$(compose_version_state)"
if [[ "$COMPOSE_STATE" != "ok" ]]; then
  fatal "${COMPOSE_STATE} Nothing has been stopped. Upgrade Compose, then re-run: https://docs.docker.com/compose/install/"
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
# unreachable.
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
# The Server ignores the variable rather than rejecting it: the config loader reads
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

# --- Configuration State Check ---
# Surface known-broken-state conditions before the customer confirms. Don't
# auto-flip security-sensitive values.

step "Checking configuration state"

# Every .env repair here sits above the version-equality exit below on purpose,
# and lives in lib-compose.sh so restore.sh performs the same ones: none of them
# is a property of the version gap. reconcile_env_file sets ENV_RECONCILED and
# MONITORING_ACTIVE; its comment carries the reasoning for each repair.
reconcile_env_file "$ENV_FILE"

# --- Grafana Credential State ---
# The installer generates GRAFANA_ADMIN_PASSWORD on a fresh monitoring install,
# and warns when a Grafana volume already exists because the password is applied
# only when the admin user is created and ignored on every later boot. Neither
# ran on the upgrade path, so an install that predates the change came out the
# far side still answering to admin/admin with nothing in the output saying so.
# The generate branch cannot apply here for the same reason it does not apply in
# the installer: the volume already pinned it.
#
# Above the exit for the same reason the reconciles are: the password is stale
# whether or not there is a version to move to, and this is the only path that
# reports it.
if [[ "$MONITORING_ACTIVE" == true ]] \
  && [[ "$(grafana_password_action "$ENV_FILE")" == "stale" ]]; then
  echo ""
  warn "Grafana is running from an existing volume, so its admin password is whatever it was first started with."
  warn "  Releases before 1.4.0 defaulted it to 'admin', which is very likely what it still is. To set a new one:"
  warn "    docker compose exec grafana grafana cli admin reset-admin-password <new-password>"
  warn "  then record it as GRAFANA_ADMIN_PASSWORD in ${ENV_FILE}."
  warn "  The shipped compose file binds Grafana to loopback; the container currently running keeps"
  warn "  whatever binding it was created with until it is recreated. Check: docker compose ps grafana"
fi

# --- Already on the target version? ---
#
# Only if the stack is actually serving it. This script writes AGLEDGER_VERSION
# before the restart, so a run whose `up -d --wait` failed left .env naming the
# target with nothing up: on re-run the equality below held, "Nothing to do"
# printed, and the recovery text the failed run gave ("set them in .env and
# re-run this script") was a no-op against a stack that was down. Ask the API,
# not `compose ps`: an unhealthy container is still `running`.
RESUMING_FAILED_UPGRADE=false
if [[ "$CURRENT_VERSION" == "$TARGET_VERSION" ]]; then
  detect_db_mode
  build_compose_cmd
  if api_service_serving; then
    if [[ "$ENV_RECONCILED" == true ]]; then
      warn "Already running version ${TARGET_VERSION}, so nothing is pulled, backed up or restarted."
      warn "The .env repairs above are on disk, but the containers still hold the environment they"
      warn "started with. Recreate the stack to pick them up:"
      warn "  (cd ${COMPOSE_DIR} && docker compose up -d)"
    elif [[ "$MONITORING_ACTIVE" == true ]] && prometheus_metrics_token_stale "$ENV_FILE"; then
      # Not a no-op, and the previous run of this script is how it got here: it
      # reconciled the fingerprint into .env, said to run `up -d`, and exited.
      # The write latched, so this run reconciles nothing and ENV_RECONCILED is
      # false. Without this branch the answer would be "Nothing to do" over a
      # Prometheus whose every scrape 401s.
      warn "Already running version ${TARGET_VERSION}, so nothing is pulled, backed up or restarted."
      warn "The bundled Prometheus is still holding an older /metrics token than .env names, so it"
      warn "is collecting nothing. Recreate the stack to hand it the current one:"
      warn "  (cd ${COMPOSE_DIR} && docker compose up -d)"
    else
      warn "Already running version ${TARGET_VERSION}. Nothing to do."
    fi
    exit 0
  fi
  RESUMING_FAILED_UPGRADE=true
  warn ".env names ${TARGET_VERSION} but the API is not serving, so this is a resumed upgrade,"
  warn "not a no-op. Continuing: applied migrations are skipped and the restart is re-attempted."
  warn "The rollback marker is left holding the version the first attempt recorded."
  warn "If the database container is down as well, and the first attempt did not itself skip the"
  warn "backup, that backup is already on disk: re-run with --skip-backup rather than fighting a"
  warn "pg_dump against a stopped Postgres."
fi

# --- Detect Database Mode ---

detect_db_mode

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
# Warning still buys the point: if the new image does fail to
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
if [[ "$RESUMING_FAILED_UPGRADE" == true ]]; then
  echo -e "${YELLOW}Finish the interrupted upgrade to ${BOLD}${TARGET_VERSION}${NC}${YELLOW}? (.env already names it; the stack is not serving)${NC}"
else
  echo -e "${YELLOW}Upgrade AGLedger from ${BOLD}${CURRENT_VERSION}${NC}${YELLOW} to ${BOLD}${TARGET_VERSION}${NC}${YELLOW}?${NC}"
fi

if [[ -t 0 ]]; then
  read -rp "Continue? (y/N) " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled."
    exit 0
  fi
else
  info "Non-interactive mode detected. Proceeding with upgrade."
fi

# --- Image Registry ---

if [[ "${AGLEDGER_IMAGE}" != "agledger/agledger" ]]; then
  step "Authenticating with private registry"
  ecr_login
fi

# --- Verify + Pull New Image ---
# Verify the new image's signature BEFORE anything runs it. The digest it
# resolves is what the rest of the upgrade runs and, at the end, what .env
# records.

# Captured, not read from `$?` after a bare call: under `set -e` a non-zero
# return from a function invoked as its own command exits the script at that
# line, so the two tailored messages below never printed and an operator whose
# pull failed for missing registry credentials got only the EXIT trap's generic
# "Upgrade failed".
#
# Exit 2 is a failed pull, not a failed signature.
VERIFY_STATUS=0
verify_image "$AGLEDGER_IMAGE" "$TARGET_VERSION" || VERIFY_STATUS=$?
case $VERIFY_STATUS in
  0) ;;
  2) fatal "Could not pull ${AGLEDGER_IMAGE}:${TARGET_VERSION} — see the authentication guidance above. The running install is untouched." ;;
  *) fatal "Image signature verification failed — aborting upgrade before running an unverified image." ;;
esac
# The verified digest for the rest of this upgrade, carried in a variable and
# handed to each command that has to run the target image, rather than written
# to .env.
#
# .env is the file a plain `docker compose up` reads, and it is also where
# AGLEDGER_VERSION lives. Writing the new digest there while that version still
# says the old one describes a stack that does not exist: any restart between
# the two, a `--force-recreate` or a rebooted host, starts the new image against
# a database this upgrade has not migrated yet. So the pin and the version move
# together, at the end, once every step that could still abort has passed.
#
# Empty when no digest resolved (verification skipped, or cosign absent). That
# also neutralises a stale pin left in .env by a prior upgrade: compose reads
# `${AGLEDGER_IMAGE_PIN:-...}`, an empty value takes the fallback, and a value
# in the process environment beats the one in .env.
TARGET_IMAGE_PIN=""
if [[ -n "${RESOLVED_DIGEST:-}" ]]; then
  TARGET_IMAGE_PIN="${AGLEDGER_IMAGE}@${RESOLVED_DIGEST}"
fi

# --- Runtime Role Gate ---
#
# Everything past this point talks to the database as the role in DATABASE_URL,
# and on an external database that role can stop being able to serve without
# anything in this install changing: a credential-rotation policy that drops
# and recreates the role brings it back without its `agledger_app` membership,
# because a GRANT does not survive a DROP ROLE.
#
# Nothing downstream says so. pg_dump reports the first table it was refused
# and prints its whole LOCK TABLE statement; `compose up --wait` reports an
# unhealthy container. Neither names the role, the grant, or agledger_app, and
# the preflight run that does is at the end of the script, past both.
#
# So it runs here, twice: once before the backup, where the answer is still
# "nothing has happened yet", and again after migrations, because a migration
# that adds tables grants them to agledger_app and a role holding a one-time
# blanket GRANT rather than membership does not receive them.
#
# The image is the TARGET version, not the running one: `--only` reaches back
# only as far as the release that added it, so asking the old image would run
# every check instead of these two and fail the upgrade on something unrelated.
# The pull and signature verification above are what make running those bytes
# here safe. How that call is made is on `upgrade_image_preflight` below.
#
# $3 is the preflight check list, defaulting to the two that decide whether the
# role can serve. `role-passwords` is added only AFTER migrations, never before:
# the migration run is what closes a placeholder role password, so asking ahead
# of it would refuse an upgrade for a condition the upgrade itself repairs.
runtime_role_gate() {
  local when="$1" recovery="$2" checks="${3:-runtime-role,pgboss}"
  # External database only. The bundled path runs one role that owns and serves
  # everything, which carries every privilege by ownership, so there is nothing
  # here to catch. It is also the path where this could refuse a good upgrade:
  # its database is a container, `--no-deps` will not start one, and an operator
  # upgrading a stopped stack would be told the role cannot connect.
  if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
    return 0
  fi
  step "Checking runtime role privileges (${when})"
  # Through preflight_gate_run for the reason install.sh uses it: the target
  # image can be OLDER than this tree (`upgrade.sh 1.7.0` from a 1.8.0
  # checkout is how an operator rolls back), and preflight refuses the whole
  # `--only` list over an id that release did not have. Left bare, that exit 2
  # reached the diagnosis text below and sent the operator hunting a role
  # problem no check had looked at.
  local rc=0
  preflight_gate_run upgrade_image_preflight "$checks" "$TARGET_VERSION" || rc=$?
  if [[ -n "$PREFLIGHT_GATE_UNCHECKED" && -z "$PREFLIGHT_GATE_RAN" ]]; then
    warn "No check in this gate exists in that image, so the gate is skipped. The full preflight run"
    warn "at the end of this script still reports on the upgraded stack."
  fi
  if [[ $rc -eq 0 ]]; then
    return 0
  fi
  echo ""
  local line
  if [[ $rc -eq 2 ]]; then
    error "The preflight gate refused its arguments, so no check ran and nothing above is a report on"
    error "your database. The line preflight printed says which refusal it was: an id this script asked"
    error "for that the ${TARGET_VERSION} image does not have and the list could not be reduced to ids"
    error "it does, or a check list this script malformed."
    while IFS= read -r line; do
      error "$line"
    done <<< "$recovery"
    fatal "Run the upgrade from the tree of the version you are upgrading to."
  fi
  error "The role in DATABASE_URL is not ready to serve. The report above is the diagnosis: a"
  error "privilege failure names the role and the exact grant to run; a connection failure names"
  error "what the connection attempt returned, which no grant will fix."
  while IFS= read -r line; do
    error "$line"
  done <<< "$recovery"
  fatal "Fix what the check reported and re-run."
}

# The runner preflight_gate_run drives, so the retry re-runs the same call with
# a reduced list. AGLEDGER_VERSION and AGLEDGER_IMAGE_PIN are passed explicitly
# because .env still names the old version, and may still carry a previous
# upgrade's digest, until the steps below update it.
#
# --no-deps: agledger-api depends on agledger-migrate completing, and the
# migration is a `run --rm` that leaves no container behind, so without it
# compose re-runs the whole migration to satisfy the dependency.
#
# NODE_OPTIONS cleared: it reaches every node process in the container and this
# invocation overrides the image argv, so it carries neither `--permission` nor
# `--allow-fs-read`. An operator who set the SIEM file-sink grant (or an APM
# `--import`) in `.env` rather than on the worker service would fail this call at
# pre-execution with ERR_MISSING_OPTION and nothing named. NODE_EXTRA_CA_CERTS,
# which is how a CA bundle reaches this image, is a different variable.
upgrade_image_preflight() {
  AGLEDGER_VERSION="${TARGET_VERSION}" AGLEDGER_IMAGE_PIN="${TARGET_IMAGE_PIN}" \
    "${COMPOSE[@]}" run --rm --no-deps -e NODE_OPTIONS= \
    --entrypoint /nodejs/bin/node agledger-api \
    dist/scripts/preflight.js --only="$1"
}

build_compose_cmd
# The recovery text has to describe the state this run is actually in. On a
# resumed run every clause of the fresh-run version is false: the first
# attempt's backup exists, its migrations are applied, .env names the target
# (that is how the resume was detected) and the stack is not serving. Telling
# an external-DB operator their database is untouched when it has already been
# migrated is how a rollback gets reached for that nothing needs.
if [[ "$RESUMING_FAILED_UPGRADE" == true ]]; then
  runtime_role_gate "before the backup" \
"This is a resumed upgrade, so read the state before acting: the first attempt's migrations for
${TARGET_VERSION} are applied and .env already names it. Nothing further has changed on THIS run.
The original restart may have failed for the same reason this check just did."
else
  runtime_role_gate "before the backup" \
"Nothing has changed yet: no backup has been taken, no migration has run, and .env still
names the version you are on, so your install is serving exactly as it was."
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

# Save pre-upgrade version for rollback.
#
# The directory is created rather than required: `--skip-backup` on a host that
# has never run backup.sh has no backup/ yet, and the README says the marker is
# always written. It is the one file that says what to roll back TO, so it is
# not something to skip because the directory it lives in is absent.
#
# Not written on a resumed run: CURRENT_VERSION equals TARGET_VERSION there, so
# writing it would overwrite the real previous version with the one being
# upgraded to and leave nothing to roll back to.
BACKUP_ROOT="$(backup_root)"
# An install upgraded from an older checkout has a marker in the old shared
# location too, naming an older version. Left unsaid, the operator reads that
# one at rollback time.
report_legacy_backup_root
if [[ "$RESUMING_FAILED_UPGRADE" == true ]]; then
  # Defaulted here rather than with `|| echo`: the reader prints nothing and
  # SUCCEEDS when no marker exists, so a `||` fallback never fires and the line
  # would end in a blank where the version belongs.
  RESUMED_MARKER="$(read_pre_upgrade_marker)"
  info "Rollback marker left as it is (resumed upgrade): ${RESUMED_MARKER:-none recorded}"
elif [[ -n "$CURRENT_VERSION" ]]; then
  mkdir -p "$BACKUP_ROOT"
  echo "$CURRENT_VERSION" > "$(pre_upgrade_marker)"
fi

# --- Stop Worker ---

step "Stopping worker (prevent job processing during migration)"

build_compose_cmd
# No `|| true` here: it swallows a FAILED stop as readily as an absent one, and
# a worker that refuses to stop goes on consuming jobs while the migration
# rewrites the schema under it. Three answers, not two: there is no worker,
# there is one, or we could not find out. A `2>/dev/null || true` turns the
# third into the first, because `compose ps -aq <name>` exits non-zero and
# writes to stderr for an unknown service, a compose file it cannot parse, a
# daemon it cannot reach and a socket it may not read. Every one of those would
# print "nothing to stop" and migrate against a worker that is running.
WORKER_PS_STATUS=0
WORKER_CONTAINER="$("${COMPOSE[@]}" ps -aq agledger-worker 2>&1)" || WORKER_PS_STATUS=$?
if [[ $WORKER_PS_STATUS -ne 0 ]]; then
  error "compose could not say whether agledger-worker exists. It reported:"
  error "  ${WORKER_CONTAINER}"
  fatal "Refusing to migrate without knowing whether a worker is processing jobs."
fi
if [[ -z "$WORKER_CONTAINER" ]]; then
  info "No worker container on this host; nothing to stop."
else
  "${COMPOSE[@]}" stop agledger-worker \
    || fatal "Could not stop agledger-worker. Refusing to migrate while it may still be processing jobs. Stop it by hand and re-run: (cd ${COMPOSE_DIR} && docker compose stop agledger-worker)"
  WORKER_STOPPED=true
  info "Worker stopped"
fi

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

AGLEDGER_VERSION="${TARGET_VERSION}" AGLEDGER_IMAGE_PIN="${TARGET_IMAGE_PIN}" \
  "${COMPOSE[@]}" run --rm agledger-migrate
info "Migrations complete"

# Again, because the migration that just ran may have added tables. The schema
# grants those to agledger_app, so a member role receives them and a role
# carrying a one-time blanket GRANT does not. Asking now is the difference
# between naming the tables and watching the restart below report "unhealthy".
runtime_role_gate "after migrations" \
"Read this one carefully, because the upgrade is part-done. The migrations for ${TARGET_VERSION}
are applied, and they are not rolled back by stopping here. The worker is stopped and stays
stopped until the upgrade finishes, so nothing is processing jobs, dispatching webhooks or
sweeping deadlines right now. The API is still serving the previous version against the new
schema. Grant what the report asks for and re-run this script to finish; the migrations it
already applied will be skipped." \
  runtime-role,role-passwords,pgboss

# --- Update Version in .env ---

step "Updating configuration"

upsert_env_var AGLEDGER_VERSION "${TARGET_VERSION}" "$ENV_FILE"
info "Updated AGLEDGER_VERSION=${TARGET_VERSION} in .env"

# The digest, in the same breath as the version it belongs to. Everything that
# had to run the target image before this point was handed it directly.
if [[ -n "$TARGET_IMAGE_PIN" ]]; then
  upsert_env_var AGLEDGER_IMAGE_PIN "$TARGET_IMAGE_PIN" "${COMPOSE_DIR}/.env"
  # Verified or not, the digest is what the upgrade runs. Only the run that
  # verified it may say so: on a host without cosign this upgrade already
  # printed "Proceeding UNVERIFIED", and the two lines have to agree.
  if [[ "${SIGNATURE_VERIFIED:-false}" == "true" ]]; then
    info "Pinned upgrade to signature-verified digest: ${RESOLVED_DIGEST}"
  else
    warn "Pinned upgrade to UNVERIFIED digest (${UNVERIFIED_REASON:-not verified}): ${RESOLVED_DIGEST}"
  fi
else
  # Drop any stale pin from a prior version so the restart runs the NEW target,
  # not the old digest.
  delete_env_var AGLEDGER_IMAGE_PIN "${COMPOSE_DIR}/.env"
fi

# --- Restart All Services ---

step "Restarting all services"

# The app containers are recreated below by the new image, but a monitoring
# service whose bind-mounted config file arrived with this upgrade is not: its
# service definition did not change, so `up -d` would leave it running on what
# it read at its last start. Done before the wait, so the wait judges the
# configuration that is on disk.
restart_mounted_config_services

# The services this run has to see come up. `up -d` starts whatever the profile
# selects, and the check after it walks names, so the monitoring four are on the
# list only when this host is running them.
UPGRADE_SERVICES=(agledger-api agledger-worker)
if [[ "$MONITORING_ACTIVE" == true ]]; then
  # shellcheck disable=SC2206  # a space-separated list of service names, no globbing wanted
  UPGRADE_SERVICES+=(${MONITORING_SERVICES})
fi

# --wait fails the upgrade if the new image crashloops at boot (e.g. a
# missing runtime asset). Without it, `up -d` returns as soon as
# the container is created, the preflight loop below logs a soft WARN, and
# the script exits 0 — handing the customer a broken upgrade with no
# visible signal anything went wrong.
#
# It is not the whole answer either: `--wait` is satisfied by a container that
# is merely running whenever the service declares no healthcheck, which the
# collector cannot (its image holds one binary and no shell), and a
# crash-looping container is running between restarts. The container states and
# the restart counter are asked for as well, the same pair install.sh asks, or
# an upgrade that leaves the collector dead on a config this release changed
# reports success.
# After restart_mounted_config_services for the reason install.sh gives at its
# own call: a user-initiated start zeroes the counter, so a baseline taken
# ahead of that restart would hide the loop it is meant to catch.
capture_compose_restart_baseline "${UPGRADE_SERVICES[@]}"
if ! "${COMPOSE[@]}" up -d --wait || ! all_compose_services_up "${UPGRADE_SERVICES[@]}"; then
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
  # Which of the two halves failed decides what is worth printing: a container
  # that is restarting, exited, unhealthy or looping is named with its own log
  # tail, and when every one reports up it is the wait that timed out and the
  # reporter has nothing to name.
  report_failed_compose_services "${UPGRADE_SERVICES[@]}" || true
  fatal "Services failed to become healthy after upgrade. Check: docker compose logs agledger-api"
fi
info "All services restarted"

# --- Preflight Check ---

step "Running preflight checks"

# /health/ready, not /health: the same endpoint the compose healthcheck and the
# image HEALTHCHECK probe. `/health` is a static 200 that opens no connection,
# so it answers on a container whose database is down, gone or refusing its
# credentials, and this loop would then declare an upgrade ready that cannot
# serve a single request. The readiness handler runs SELECT 1.
ELAPSED=0
MAX_WAIT=30
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  # NODE_OPTIONS cleared for the reason given at the privilege check above;
  # `exec` inherits the running container's environment, which carries .env.
  if "${COMPOSE[@]}" exec -e NODE_OPTIONS= agledger-api /nodejs/bin/node -e \
    "fetch('http://localhost:3000/health/ready').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))" \
    2>/dev/null; then
    break
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [[ $ELAPSED -ge $MAX_WAIT ]]; then
  warn "API did not become ready within ${MAX_WAIT}s. Continuing with checks..."
fi

# preflight exits 0 when everything passed OR when the worst it found was a
# warning, and 1 only when a check FAILED. A non-zero here is therefore a
# failing check, and is reported as one.
#
# Not fatal: the upgrade is complete and the new version is serving, so stopping
# here would report a failure over a stack that is up. Said plainly instead.
if ! "${COMPOSE[@]}" exec -e NODE_OPTIONS= agledger-api /nodejs/bin/node dist/scripts/preflight.js 2>&1; then
  echo ""
  error "Preflight reported FAILING checks, listed with a ✗ above. These are not warnings:"
  error "each one names something the Server needs and does not have. The upgrade itself"
  error "completed; fix what the report names and re-run this script to re-check."
fi

# --- Version Verification ---

step "Verifying upgrade"

# /health/ready carries the same `version` field, and reading it from there
# makes one answer cover both questions this step has: which version came up,
# and whether it can reach its database. A version read off the static /health
# would report a successful upgrade on a Server that 500s its first request.
HEALTH_RESPONSE=$("${COMPOSE[@]}" exec -e NODE_OPTIONS= agledger-api /nodejs/bin/node -e \
  "fetch('http://localhost:3000/health/ready').then(r=>r.json()).then(d=>console.log(JSON.stringify(d))).catch(e=>console.error(e))" \
  2>/dev/null || echo "{}")

# POSIX sed rather than two chained `grep -oP`: BSD grep (macOS) has no -P, and
# sed prints nothing instead of failing when /health returned {}, so the
# fallback moves into the expansion.
HEALTH_VERSION=$(echo "$HEALTH_RESPONSE" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
HEALTH_VERSION="${HEALTH_VERSION:-unknown}"
if [[ "$HEALTH_VERSION" == "$TARGET_VERSION" ]]; then
  info "/health/ready reports version: ${HEALTH_VERSION}"
elif [[ "$HEALTH_VERSION" != "unknown" ]]; then
  warn "/health/ready reports version ${HEALTH_VERSION}, expected ${TARGET_VERSION}"
else
  warn "Could not verify version from /health/ready endpoint"
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
echo -e "    curl -s http://localhost:$(resolve_host_port AGLEDGER_HOST_PORT 3001)/health/ready | jq ."
echo -e "    docker compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
echo ""
echo -e "${GREEN}=============================================================================${NC}"
