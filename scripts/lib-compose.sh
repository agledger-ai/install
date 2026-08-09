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
    # A file whose last line carries no newline would otherwise get the new
    # assignment glued onto it, corrupting the existing variable and the new
    # one in a single append. `.env` is documented as hand-editable and plenty
    # of tooling writes a final line without a terminator, so this is reachable
    # rather than theoretical. Command substitution strips a trailing newline,
    # so an empty result means the file already ends in one.
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
      echo "" >> "$file"
    fi
    echo "${key}=${value}" >> "$file"
  fi
}

# Compose project name for this checkout. Compose derives it from the directory
# holding the first -f file, lowercased with anything outside [a-z0-9_-] dropped,
# which comes out as `compose` in every checkout of the install repo. The
# containers, network and volumes it names are therefore shared by every
# checkout on the host, and they outlive both `docker compose down` and deleting
# the checkout. Exporting COMPOSE_PROJECT_NAME (compose reads it natively;
# install.sh persists it into .env) gives a checkout its own set instead.
compose_project_name() {
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    printf '%s' "${COMPOSE_PROJECT_NAME}"
    return
  fi
  installed_project_name
}

# The project this checkout's .env already describes, ignoring whatever the
# caller exported for this run. Compose reads COMPOSE_PROJECT_NAME out of the
# env file, so a name persisted by an earlier install is authoritative; with no
# name recorded, the stack lives under Compose's own derivation from the
# directory. This is the "what is already installed here" half of the
# comparison that `project_switch_orphans_install` makes.
installed_project_name() {
  local persisted
  persisted="$(get_env_value COMPOSE_PROJECT_NAME "${COMPOSE_DIR}/.env")"
  if [[ -n "$persisted" ]]; then
    printf '%s' "$persisted"
    return
  fi
  basename "${COMPOSE_DIR}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-'
}

# True when .env holds credentials a completed install generated, as opposed to
# a bare copy of .env.example (whose VAULT_SIGNING_KEY is present but empty) or
# a tree that has never finished an install.
env_file_carries_install_state() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 1
  if [[ -n "$(get_env_value PLATFORM_API_KEY "$env_file")" ]]; then return 0; fi
  if [[ -n "$(get_env_value VAULT_SIGNING_KEY "$env_file")" ]]; then return 0; fi
  return 1
}

# True when the named compose project still has something on this host: its
# bundled data volume, or containers (running or stopped).
#
# This is the difference between "installed" and "was installed", and .env
# cannot answer it. `uninstall.sh` without `--purge` does `down -v` and
# deliberately KEEPS .env so a reinstall preserves the signing key, which leaves
# a file that still looks like a completed install describing a stack that no
# longer exists. Nothing is there to orphan, so a project switch is free.
installed_project_has_state() {
  local project="$1"
  if docker volume inspect "${project}_pgdata" &>/dev/null; then return 0; fi
  # An external-database install has no bundled volume, so containers are the
  # only trace. `-a` because a stopped stack is still an install.
  if [[ -n "$(docker ps -aq --filter "label=com.docker.compose.project=${project}" 2>/dev/null)" ]]; then
    return 0
  fi
  return 1
}

# True when this run would point the checkout at a DIFFERENT compose project
# than the one its .env already describes.
#
# There is one .env per checkout and it is the whole state of the install that
# lives there: ports, project name, signing key, platform key, issuer URL.
# Running install.sh in an installed tree under a second project name creates a
# genuinely separate stack (own containers, network and volume) but rewrites
# that single .env to describe the new one, so the first stack keeps serving
# while every later `docker compose`, upgrade.sh and uninstall.sh from that
# directory addresses the second. The first stack is still running and is no
# longer reachable by the tooling that made it.
#
# The second stack comes up wrong as well: an existing .env means secrets are
# not regenerated, so it inherits the first stack's VAULT_SIGNING_KEY (two
# independent chains signed by one identity), and AGLEDGER_EXTERNAL_URL is only
# rewritten on a fresh .env, so it signs records claiming the first stack's
# issuer and port.
#
# So a side-by-side install needs its own directory, which is what install.sh
# now says. Isolating containers is not the hard part; isolating state is.
#
# Gated on the old stack still existing. A directory that was installed and then
# uninstalled has nothing left to orphan, and refusing there would block the
# reinstall-under-a-new-name that `uninstall.sh` invites by keeping .env.
project_switch_orphans_install() {
  local requested="$1" installed
  [[ -n "$requested" ]] || return 1
  env_file_carries_install_state "${COMPOSE_DIR}/.env" || return 1
  installed="$(installed_project_name)"
  [[ "$requested" != "$installed" ]] || return 1
  installed_project_has_state "$installed"
}

# True when a fresh install would write credentials the existing data volume
# will never accept: bundled Postgres, no .env to inherit the old password from,
# and a data directory that is already initialized. Postgres only applies
# POSTGRES_PASSWORD when it initializes an empty data directory, so on a
# surviving volume the generated password authenticates against nothing.
#
# Reads DATABASE_URL from the environment the same way detect_db_mode does, so
# a bundled-PG URL (localhost/postgres host) is classified as bundled rather
# than waved through as external.
stale_pgdata_blocks_install() {
  local external_flag="${1:-false}"
  [[ "$external_flag" == "true" ]] && return 1
  detect_db_mode
  [[ "${USES_BUNDLED_PG}" == "true" ]] || return 1
  [[ -f "${COMPOSE_DIR}/.env" ]] && return 1
  # Only an INITIALIZED data directory holds a password this install cannot
  # reproduce. A volume compose created and never populated (interrupted first
  # bring-up, then the checkout deleted and re-run) blocked the install over a
  # database that does not exist. `unknown` blocks, matching the same
  # both-directions-safe choice `pg_password_action` makes.
  case "$(pgdata_volume_state)" in
    initialized|unknown) return 0 ;;
    *) return 1 ;;
  esac
}

# Volume holding the bundled Postgres data directory for this project.
compose_pgdata_volume() {
  printf '%s_pgdata' "$(compose_project_name)"
}

# True when that volume already exists on this Docker host, i.e. a previous
# install's database is still present even if its containers and its checkout
# are long gone.
pgdata_volume_exists() {
  docker volume inspect "$(compose_pgdata_volume)" &>/dev/null
}

# What the bundled Postgres volume actually holds. Echoes one of:
#
#   absent       no such volume.
#   empty        the volume exists but no database was ever initialized in it.
#   initialized  a real data directory, which pins a password.
#   unknown      the probe could not run, so the caller must assume nothing.
#
# The empty/initialized distinction is load-bearing for credential decisions.
# Compose creates the volume when it creates the container, so an interrupted
# or failed first bring-up (and a bare `docker volume create`) leaves an empty
# one. Only an initialized directory pins a password, because initdb is the
# only time Postgres applies POSTGRES_PASSWORD. `PG_VERSION` is the marker the
# postgres image's own entrypoint checks.
#
# `unknown` is reported rather than folded into either real answer, because
# the two wrong guesses fail in opposite directions and the caller is the only
# one that knows which one it is about to make. It IS reachable: an air-gapped
# host, a registry 429, or a daemon that cannot start the probe.
#
# Runs the agledger image (already resolved, verified and pinned by digest at
# this point) rather than pulling a floating third-party `busybox:latest` into
# an install that goes to lengths elsewhere to run only verified bytes. As
# root, because a PGDATA directory is mode 0700 owned by the postgres uid and
# the image's own non-root uid cannot stat it, which would read as `empty` on
# a live database: the single most dangerous wrong answer here.
pgdata_volume_state() {
  local volume
  volume="$(compose_pgdata_volume)"
  docker volume inspect "$volume" &>/dev/null || { echo absent; return; }

  local out rc
  out=$(docker run --rm --user 0:0 -v "${volume}:/pgdata:ro" --entrypoint sh \
    "${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${AGLEDGER_VERSION}}" \
    -c 'test -f /pgdata/PG_VERSION && echo INIT || echo EMPTY' 2>/dev/null)
  rc=$?
  if [[ $rc -ne 0 || -z "$out" ]]; then
    echo unknown
  elif [[ "$out" == *INIT* ]]; then
    echo initialized
  else
    echo empty
  fi
}

# Read KEY=VALUE from an env file, stripping inline comments (whitespace + '#')
# and surrounding whitespace — matching docker-compose's native parser. Naive
# `cut -d= -f2-` leaves inline comments in place and defeats equality checks
# against values like "true" (.env.example ships trailing comments). (F-415)
# Returns empty string if the key is absent.
# Usage: VALUE=$(get_env_value KEY FILE)
get_env_value() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  # `|| true` is load-bearing: callers run under `set -euo pipefail`, where a
  # no-match `grep` exits 1 and pipefail propagates it out of the command
  # substitution, killing the script with no message. An absent key is the
  # normal case (every commented-out line in .env.example), so it must return
  # empty and succeed, per the contract above.
  # Match the way docker-compose's dotenv parser matches, because the whole
  # point of this function is to answer what the CONTAINERS will receive.
  # `^KEY=` alone is narrower than compose on four counts, and each gap makes
  # this function confidently report "unset" for a value that is very much set:
  #
  #   export KEY=v     a spelling operators reach for by habit
  #    KEY=v           a leading space, from hand-editing
  #   KEY = v          spaces around the equals
  #   KEY=a\nKEY=b     duplicates, where compose takes the LAST and this took
  #                    the first
  #
  # The last two `sed`s strip an inline comment and then one matched pair of
  # surrounding quotes, both of which compose also strips. Without the quote
  # strip a hand-written `POSTGRES_PASSWORD="s3cret"` reads back WITH the
  # quotes here and without them in every container.
  #
  # Getting this wrong is not a cosmetic mismatch. Callers decide whether to
  # GENERATE a value from it, so a false "unset" overwrites something real:
  # a database password (fails loudly, locally, at connect) or the federation
  # identity peers have stored (fails silently, remotely, and only on their
  # side).
  grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" 2>/dev/null \
    | tail -1 \
    | sed -E "s|^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=||; s|[[:space:]]+#.*$||" \
    | tr -d '[:space:]' \
    | sed -E "s|^\"(.*)\"$|\\1|; s|^'(.*)'$|\\1|" || true
}

# The bundled-Postgres connection string, built from an env file the way the
# compose files build it, defaults included.
#
# The defaults are the whole point. `POSTGRES_USER` and `POSTGRES_DB` reach a
# fresh `.env` only because the installer copies `.env.example`; a `.env` the
# operator wrote by hand carries neither, and every container still connects
# because docker-compose.yml spells them `${POSTGRES_USER:-agledger}`. Anything
# run OUTSIDE compose (`docker run --env-file`) does not get that substitution,
# so reading the keys raw yields `postgresql://:pw@postgres:5432/`, which
# Postgres rejects with "no PostgreSQL user name specified in startup packet".
#
# Returns 1 with nothing on stdout when the password is absent, which is the
# other way this URL goes silently wrong.
# Usage: URL=$(bundled_database_url FILE)
bundled_database_url() {
  local file="$1" user pass db
  user=$(get_env_value POSTGRES_USER "$file")
  pass=$(get_env_value POSTGRES_PASSWORD "$file")
  db=$(get_env_value POSTGRES_DB "$file")
  [[ -n "$pass" ]] || return 1
  echo "postgresql://${user:-agledger}:${pass}@postgres:5432/${db:-agledger}"
}

# What value, if any, this run should record for POSTGRES_USER / POSTGRES_DB.
#
# Echoes the value to write, or nothing when the file already carries one and
# the operator's choice must be left alone. Both keys reach a fresh `.env` only
# because the installer copies `.env.example`, so a `.env` written by hand has
# neither and the file misreports the identity of the database compose in fact
# created.
#
# The exported value wins over the default because compose reads the
# environment ahead of `.env`: an operator who exports POSTGRES_USER got a
# database owned by that user, and writing `agledger` over it would make the
# file disagree with what exists.
#
# Usage: VALUE=$(pg_identity_to_record KEY FILE "${!KEY:-}")
pg_identity_to_record() {
  local key="$1" file="$2" exported="${3:-}"
  [[ -n "$(get_env_value "$key" "$file")" ]] && return 0
  echo "${exported:-agledger}"
}

# A random UUID v4, from whatever this host has.
#
# `uuidgen` is not on a minimal container host, `/proc/sys/kernel/random/uuid`
# is Linux-only, and python3 is not guaranteed either. openssl is, because the
# installer already generates every other secret with it.
generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  # Hand-assembled v4: 16 random bytes with the version and variant nibbles set.
  local hex out
  hex=$(openssl rand -hex 16) || return 1
  out=$(printf '%s-%s-4%s-%s%s-%s' \
    "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" \
    "$(printf '%x' $(( 0x8 + (0x${hex:16:1} % 4) )))" "${hex:17:3}" \
    "${hex:20:12}")
  # An openssl that exits 0 with empty output would assemble the literal
  # `--4-8-` and every arm of this reports success, so the caller has to be
  # told by the exit code, not by the string.
  is_uuid "$out" || return 1
  echo "$out"
}

# True when a string is a UUID, which is the only thing a federation hub-id can
# be: peers store it and the receiver looks this Server up by it.
is_uuid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# Whether this run should mint a federation identity for the Server, per the
# same rule the engine's `localHubId()` applies.
#
# Echoes `generate` when neither AGLEDGER_INSTANCE_ID nor the legacy
# AGLEDGER_ORGANIZATION_ID fallback holds a UUID, and nothing when one does.
#
# The "one does" case is the important half. Writing a fresh id over a Server
# that already has a usable one would change the identity its peers have stored
# and 401 every message after the next restart. There is no such hazard in the
# other direction: a Server whose id is absent or is the old literal "default"
# cannot have completed a handshake, because the peer's schema declares
# `peerHubId` as `format: uuid` and refuses it (#1193).
federation_hub_id_action() {
  local file="$1"
  is_uuid "$(get_env_value AGLEDGER_INSTANCE_ID "$file")" && return 0
  is_uuid "$(get_env_value AGLEDGER_ORGANIZATION_ID "$file")" && return 0
  echo generate
}

# What this run should do about POSTGRES_PASSWORD. Echoes one of:
#
#   keep      the file carries a password. Never regenerate: Postgres applies
#             POSTGRES_PASSWORD only when initializing an EMPTY data
#             directory, so a fresh one authenticates against nothing (28P01).
#   generate  no password, and no volume has been initialized with one.
#   refuse    no password, but a data volume exists (or might). Generating
#             would lock the operator out of their own database; the caller
#             prints the three-way remedy instead.
#
# Set means chosen, with one exception this cannot retire: a password that
# appeared in a released `.env.example` is readable by anyone and was never
# chosen by the operator. `.env.example` ships the key empty now, so new files
# cannot reach that state, but files written against v1.3.4 and earlier can and
# do (that installer skipped secret generation entirely when `.env` already
# existed, so `cp .env.example .env` before a first install left the published
# value on disk).
#
# The question is deliberately NOT "is this the placeholder", which is the
# identity check that kept being subtly wrong. It is "are we about to hand
# initdb a password anyone can read", which only matters on the one path where
# a database does not exist yet, and is answered by a fixed historical list
# that no longer tracks the shipped file.
PUBLISHED_PG_PASSWORDS=('agledger')

pg_password_is_published() {
  local candidate="$1" published
  for published in "${PUBLISHED_PG_PASSWORDS[@]}"; do
    [[ "$candidate" == "$published" ]] && return 0
  done
  return 1
}

pg_password_action() {
  local file="$1" external_flag="${2:-false}" current
  current="$(get_env_value POSTGRES_PASSWORD "$file")"

  # Fast path, and the overwhelmingly common one: a real password, kept without
  # paying for the volume probe below.
  if [[ -n "$current" ]] && ! pg_password_is_published "$current"; then
    echo keep
    return
  fi

  # An external database has no bundled volume to conflict with.
  if [[ "$external_flag" == "true" ]]; then
    echo generate
    return
  fi

  case "$(pgdata_volume_state)" in
    initialized)
      # The volume pins whatever it was built with. A file naming a password
      # is naming THAT one, published or not, and regenerating would lock the
      # operator out (28P01). A file naming none cannot be reconciled with it
      # at all, so say so rather than guess.
      if [[ -n "$current" ]]; then echo keep; else echo refuse; fi
      ;;
    unknown)
      # Safe in both directions is the only option here: generating might
      # target a live database and lock the operator out; keeping might hand
      # initdb a published password. Refusing costs a message and destroys
      # nothing.
      echo refuse
      ;;
    *)
      # absent or empty: no database exists, so nothing is pinned and a
      # published password is simply replaced.
      echo generate
      ;;
  esac
}

# What this run should do about GRAFANA_ADMIN_PASSWORD. Echoes keep, generate
# or stale, on the same reasoning as pg_password_action above: Grafana writes
# GF_SECURITY_ADMIN_PASSWORD into grafana.db when it creates the admin user and
# ignores it on every later boot, so the volume pins the password exactly the
# way an initialized PGDATA does.
#
#   keep      .env names one. Never regenerate.
#   generate  no password, and no Grafana volume, so the value this run writes
#             is the one the first boot will apply.
#   stale     no password, but a volume exists. Whatever it was initialized
#             with is the live login (before this change compose defaulted it to
#             `admin`, so on an install that predates it, that is what it is).
#             Writing a fresh password here would record a credential that does
#             not work, which is worse than the weak one it replaces.
#
# No `unknown` branch: unlike the Postgres case, guessing wrong destroys
# nothing. Both wrong answers cost a message, so the volume's existence, which
# needs no container to answer, is enough.
grafana_password_action() {
  local file="$1"
  if [[ -n "$(get_env_value GRAFANA_ADMIN_PASSWORD "$file")" ]]; then
    echo keep
    return
  fi
  if docker volume inspect "$(compose_project_name)_grafana-data" &>/dev/null; then
    echo stale
    return
  fi
  echo generate
}

# Production prerequisites the Server fail-fasts on at config load, checked
# against a finished .env before anything is started.
#
# The Server refusing to boot is correct; what was not is where the operator
# found out. Compose surfaces the refusal as "container is unhealthy", the
# fatal naming the variable lands in the container log, and the keys came up
# one per install run (#1163). This reports the whole set at once, on the host,
# before the pull.
#
# Prints one gap per line: a headline, then remedy lines indented four spaces.
# Empty output means nothing is missing. Mirrors the `if (isProd)` block in
# src/config.ts; the two are kept in step by hand.
#
# Usage: while IFS= read -r gap; do ...; done < <(missing_prod_config FILE)
missing_prod_config() {
  local file="$1" db_url node_env
  # Every gate below is scoped to production, exactly as config.ts scopes them.
  #
  # Absent counts as production: the image bakes `ENV NODE_ENV=production` and
  # compose does not override it, so a .env that omits the variable still boots
  # a production Server and still hits every fail-fast below. Reading absent as
  # "not production" would make this gate inert on precisely the hand-written
  # .env it exists for, which is the one that omits NODE_ENV.
  node_env="$(get_env_value NODE_ENV "$file")"
  [[ -z "$node_env" || "$node_env" == "production" ]] || return 0

  if [[ -z "$(get_env_value VAULT_SIGNING_KEY "$file")" ]]; then
    echo "VAULT_SIGNING_KEY is unset. It signs every chain entry."
    echo "    generate: docker run --rm ${AGLEDGER_IMAGE:-agledger/agledger}:${AGLEDGER_VERSION:-latest} dist/scripts/generate-signing-key.js"
  fi

  if [[ -z "$(get_env_value AGLEDGER_EXTERNAL_URL "$file")" ]]; then
    echo "AGLEDGER_EXTERNAL_URL is unset. It is the issuer (\`iss\`) signed into every record."
    echo "    set it to where this instance is reachable, e.g. https://agledger.example.com"
    echo "    no public domain? AGLEDGER_EXTERNAL_URL=https://localhost opts into a placeholder issuer."
  fi

  # Only meaningful once a DATABASE_URL exists: the bundled path composes one
  # from POSTGRES_* at container start, and config.ts skips the check when the
  # variable is empty for the same reason.
  db_url="$(get_env_value DATABASE_URL "$file")"
  if [[ -n "$db_url" ]] \
    && [[ "$db_url" != *"sslmode="* ]] \
    && [[ "$(get_env_value ALLOW_DB_WITHOUT_SSL "$file")" != "true" ]]; then
    echo "DATABASE_URL has no sslmode= and ALLOW_DB_WITHOUT_SSL is not true."
    echo "    add sslmode=require to DATABASE_URL, or set ALLOW_DB_WITHOUT_SSL=true (not recommended)."
  fi
}

# Sort `X.Y.Z` versions low to high on stdin, so `| tail -1` is the newest.
#
# Field-wise numeric sort, not `sort -V`: -V is a GNU extension and BSD sort
# (macOS) errors out on it, which would leave version resolution returning
# nothing at all. Both call sites filter to bare numeric triples first, so the
# two orderings are identical, including 1.9.0 < 1.10.0 (which a plain lexical
# sort gets backwards). A prerelease suffix would need -V semantics, so keep
# the `^[0-9]+\.[0-9]+\.[0-9]+$` filter ahead of this.
sort_semver() {
  sort -t. -k1,1n -k2,2n -k3,3n
}

# Read the private key out of `generate-signing-key.js` output.
#
# POSIX sed, not `grep -oP`: PCRE lookbehind is a GNU extension and macOS ships
# BSD grep, which fails the whole pipeline with "invalid option -- P". macOS is
# a supported install platform, so nothing here may depend on GNU-only tools.
# Anchored at line start, because the value is what the generator prints there
# and a mention of the name in the NOTE below it must not match.
parse_signing_key() {
  sed -n 's/^VAULT_SIGNING_KEY=\([^[:space:]][^[:space:]]*\).*/\1/p' | head -1
}

# --- Host ports ---

# Resolve the host side of a published port: an exported variable wins, then a
# value an earlier install persisted into .env, then the stock default. Same
# precedence COMPOSE_PROJECT_NAME follows, so a re-run without the variable
# keeps the ports the install actually came up on.
# Usage: PORT=$(resolve_host_port AGLEDGER_HOST_PORT 3001)
resolve_host_port() {
  local key="$1" default="$2" persisted
  if [[ -n "${!key:-}" ]]; then
    printf '%s' "${!key}"
    return
  fi
  persisted="$(get_env_value "$key" "${COMPOSE_DIR}/.env")"
  printf '%s' "${persisted:-$default}"
}

# True when a host port has to be written into the env file for .env to agree
# with the port this run actually published. Compose interpolates these out of
# .env, so a stale value sends the next bare `docker compose up -d` (or
# upgrade.sh, or support-bundle.sh) to a different port than the install serves.
#
# Writing back the DEFAULT matters as much as writing a non-default: moving a
# stack from 3011 back to 3001 leaves a persisted 3011 behind otherwise, and an
# exported value only wins for the run that exports it. The one case that needs
# no write is nothing recorded and the default in force, so a stock install
# keeps the commented-out .env.example lines that document the knob.
# Usage: if host_port_needs_persisting KEY VALUE DEFAULT FILE; then ...
host_port_needs_persisting() {
  local key="$1" value="$2" default="$3" file="$4" existing
  existing=$(get_env_value "$key" "$file")
  [[ "$existing" == "$value" ]] && return 1
  [[ -z "$existing" && "$value" == "$default" ]] && return 1
  return 0
}

# True when the value is a usable TCP port. Rejects 0 (compose reads it as
# "pick any free port", which would publish the API somewhere the summary URL
# does not name) and anything non-numeric.
valid_host_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

# True when something on this host answers on 127.0.0.1:PORT. Uses bash's own
# /dev/tcp so the installer takes no dependency on lsof/ss/netstat, which are
# absent from plenty of minimal hosts.
#
# Best-effort, and deliberately so. It catches loopback binds and 0.0.0.0 binds
# (which answer on loopback too), which covers the API and Postgres mappings,
# both loopback-only. It does NOT catch a listener bound to a single
# non-loopback address, so a monitoring port held on e.g. 192.168.1.5 still
# reaches the daemon as "port is already allocated". Probing every interface
# would mean parsing `ip`/`ifconfig` output across Linux and macOS for a case
# this check exists only to make friendlier, not to guarantee.
host_port_in_use() {
  local port="$1"
  # The subshell owns the descriptor, so it is closed on return either way.
  (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

# True when the port is held by a container of THIS compose project, i.e. by
# the stack we are about to reconcile rather than by a stranger. Re-running the
# installer against a live install is a supported path, so its own published
# ports must never read as a collision.
host_port_held_by_this_project() {
  local port="$1" project mapping hostspec lo hi
  project="$(compose_project_name)"
  # A published mapping renders as `127.0.0.1:3001->3000/tcp`, so the host port
  # is what sits between the last ':' and the '->'.
  #
  # #1180: docker COLLAPSES contiguous published ports into a single range
  # entry, `0.0.0.0:4317-4318->4317-4318/tcp`. The anchored `:PORT->` match
  # this used to be found every singly-rendered port and no port inside a
  # range, so the own-stack exemption worked for the API on 3001 and the
  # collector's metrics port on 8889 while failing for its OTLP pair. Re-running
  # `install.sh --with-monitoring` on its own directory then refused on 4317 and
  # 4318, held by that install's own otel-collector, and advised standing up a
  # second stack somewhere else.
  #
  # Entries with no `->` (an unpublished `8080/tcp`) fall through both branches
  # and match nothing, which is correct: they hold no host port.
  while IFS= read -r mapping; do
    [[ -z "$mapping" ]] && continue
    hostspec="${mapping%%->*}"   # 0.0.0.0:4317-4318   (or [::]:5000)
    hostspec="${hostspec##*:}"   # 4317-4318
    case "$hostspec" in
      *-*)
        lo="${hostspec%%-*}"
        hi="${hostspec##*-}"
        [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ ]] || continue
        if (( port >= lo && port <= hi )); then return 0; fi
        ;;
      *)
        if [[ "$hostspec" == "$port" ]]; then return 0; fi
        ;;
    esac
  done < <(docker ps --filter "label=com.docker.compose.project=${project}" --format '{{.Ports}}' 2>/dev/null \
             | tr ',' '\n' | tr -d ' ')
  return 1
}

# The profile-gated services. Compose only acts on these when their profile is
# selected, which is what makes them invisible to a bare `up -d`.
MONITORING_SERVICES="otel-collector jaeger prometheus grafana"

# True when this project currently has a monitoring container running, i.e. the
# install was stood up with --with-monitoring whether or not .env says so.
#
# #1180: `install.sh` persists COMPOSE_PROFILES=monitoring so later compose
# commands keep the profile, but an install predating that has no such line.
# `upgrade.sh` then ran `up -d` with the profile unselected: compose left the
# monitoring containers running, untouched, on their old image and old port
# bindings, while reporting a successful upgrade. The containers themselves are
# the only honest answer to "is monitoring part of this install", so ask them.
monitoring_containers_running() {
  local project
  project="$(compose_project_name)"
  docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null \
    | grep -qxE "$(printf '%s' "$MONITORING_SERVICES" | tr ' ' '|')"
}

# Ensure COMPOSE_PROFILES in $1 selects `monitoring`. Echoes `added` when it had
# to write, `present` when it was already there. Same upsert install.sh does, so
# an upgrade repairs the .env rather than special-casing this run.
ensure_monitoring_profile() {
  local file="$1" existing
  existing="$(get_env_value COMPOSE_PROFILES "$file")"
  if [[ ",${existing}," == *",monitoring,"* ]]; then
    echo present
    return
  fi
  upsert_env_var COMPOSE_PROFILES "${existing:+${existing},}monitoring" "$file"
  echo added
}

# First port at or above $1 that nothing on this host answers on and that is not
# in the space-delimited exclusion list $2.
#
# Exists so the installer never prints a suggested command line carrying a port
# it has just rejected. Walking up from the requested value keeps the suggestion
# recognisable (3011 -> 3012) instead of jumping somewhere arbitrary, and the
# exclusion list stops two variables in the same suggestion landing on one port.
#
# Best-effort in exactly the way host_port_in_use is: a listener bound to a
# single non-loopback address is invisible here, so this narrows the odds of a
# second collision rather than eliminating them. Always exits 0, because under
# `set -euo pipefail` a non-zero return inside `$(...)` kills the caller, and
# every callsite is building an error message where that would be the worse
# failure. With nothing free in the window it returns the port it was given.
next_free_host_port() {
  local port="$1" excluded=" ${2:-} " probed=0
  while (( probed < 200 && port <= 65535 )); do
    if [[ "$excluded" != *" ${port} "* ]] && ! host_port_in_use "$port"; then
      printf '%s' "$port"
      return 0
    fi
    port=$(( port + 1 ))
    probed=$(( probed + 1 ))
  done
  printf '%s' "$1"
}

# Build the "VAR=port VAR=port " prefix for a command line the installer
# suggests. A port that is usable keeps the value the operator asked for; one
# that is not is replaced with the next free port.
#
# Every suggested command line goes through this. Hardcoded literals are what
# made the side-by-side recipe hand back the ports the stack it was installing
# alongside already held, and the collision example repeat the two values it had
# just rejected (#1129).
#
# The two scopes ask genuinely different questions, which is why "usable" is
# measured differently in each:
#
#   conflicting  What has to move for THIS run to start? That is the preflight's
#                answer, CONFLICTING_PORTS_LIST, and it deliberately excludes
#                ports held by this run's own compose project: re-running the
#                installer against a live stack must not read its own published
#                ports as a collision. Prints only the variables that move.
#
#   all          What has to be free for a SECOND stack, in a fresh directory,
#                under a different project name? Every port it publishes, and
#                the preflight's answer does not transfer: a port held by the
#                stack next door was exempt there (same derived project name)
#                and is a hard collision here. So this scope re-probes the host
#                directly rather than trusting the conflict list.
#
# Reads the caller's PORTS_TO_PUBLISH ("VAR=port=label" specs) and
# CONFLICTING_PORTS_LIST (space-delimited, with sentinel spaces).
suggest_port_assignments() {
  local scope="${1:-all}"
  local out="" reserved="" spec port_var rest port suggested
  # Ports staying put reserve their number. A port that is about to move does
  # not: holding it would push its own replacement one higher for no reason.
  for spec in "${PORTS_TO_PUBLISH[@]}"; do
    rest="${spec#*=}"
    port="${rest%%=*}"
    _port_must_move "$port" "$scope" || reserved="${reserved} ${port}"
  done
  for spec in "${PORTS_TO_PUBLISH[@]}"; do
    port_var="${spec%%=*}"
    rest="${spec#*=}"
    port="${rest%%=*}"
    if _port_must_move "$port" "$scope"; then
      suggested="$(next_free_host_port "$port" "$reserved")"
      reserved="${reserved} ${suggested}"
    else
      [[ "$scope" == "conflicting" ]] && continue
      suggested="$port"
    fi
    out="${out}${port_var}=${suggested} "
  done
  printf '%s' "$out"
}

# Whether a port in a suggested command line has to be renumbered. See the
# scope table above for why the two answers differ.
_port_must_move() {
  local port="$1" scope="$2"
  if [[ "$scope" == "conflicting" ]]; then
    [[ "${CONFLICTING_PORTS_LIST:- }" == *" ${port} "* ]]
  else
    host_port_in_use "$port"
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

# --- Supply-chain verification (keyless cosign) ---

# The release pipeline (release.yml) keyless-signs every public image + chart via
# GitHub OIDC -> Fulcio -> public Rekor. These identify a genuine AGLedger
# release signature; verification is fully offline against the Sigstore trust
# root and needs NO access to the (private) source repo.
AGLEDGER_SIGNER_IDENTITY_REGEXP='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
AGLEDGER_SIGNER_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# Pull + cryptographically verify a Docker Hub image BEFORE anything runs it,
# then expose its digest in the global RESOLVED_DIGEST. The image is executed to
# mint the vault signing key, so an unverified/tampered image is silent RCE +
# key exfiltration — this is the gate that closes that (cross-repo #667-C1).
#
# Policy (OOTB-first: a default install must still boot):
#   AGLEDGER_SKIP_VERIFY=true      -> skip entirely (dev/local ONLY), warn.
#   custom/private --image         -> skip (not signed by our pipeline), warn.
#   cosign present + verify FAILS   -> abort (fail closed). The RCE gate.
#   cosign present + verify OK      -> proceed.
#   cosign absent                  -> warn loudly + proceed, UNLESS
#                                     AGLEDGER_REQUIRE_VERIFY=true (then abort).
# Returns non-zero only when the caller should abort. Sets RESOLVED_DIGEST
# whenever the pull succeeded (verified or not) so callers can still digest-pin.
verify_image() {
  local image="$1" version="$2"
  local ref="${image}:${version}"
  RESOLVED_DIGEST=""

  step "Verifying image signature"

  if ! docker pull "$ref"; then
    error "docker pull ${ref} failed — cannot verify or run an image that isn't present."
    return 1
  fi
  # Resolve the digest for THIS repo specifically — RepoDigests can carry entries
  # for other repos the same image ID was previously pulled under (mirror/ECR),
  # so blindly taking [0] could yield a foreign digest. Accept only a well-formed
  # sha256; otherwise leave empty so callers skip pinning rather than write junk.
  RESOLVED_DIGEST=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null \
    | grep "^${image}@" | head -1 | sed 's/.*@//' || true)
  [[ "$RESOLVED_DIGEST" == sha256:* ]] || RESOLVED_DIGEST=""

  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    warn "AGLEDGER_SKIP_VERIFY=true — skipping image signature verification (dev/local ONLY, never production)."
    return 0
  fi
  if [[ "$image" != "agledger/agledger" ]]; then
    warn "Custom image '${image}' is not signed by the AGLedger release pipeline — skipping signature verification."
    return 0
  fi
  if ! command -v cosign &>/dev/null; then
    if [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
      error "cosign not installed and AGLEDGER_REQUIRE_VERIFY=true."
      error "Install cosign 3.x: https://docs.sigstore.dev/system_config/installation/"
      return 1
    fi
    warn "cosign not installed — cannot cryptographically verify the image before running it."
    warn "Install cosign 3.x to enable supply-chain verification: https://docs.sigstore.dev/system_config/installation/"
    warn "Proceeding UNVERIFIED. Set AGLEDGER_REQUIRE_VERIFY=true to make this fatal."
    return 0
  fi

  # cosign's own output goes to stderr; we report the result ourselves.
  if cosign verify \
       --certificate-identity-regexp "$AGLEDGER_SIGNER_IDENTITY_REGEXP" \
       --certificate-oidc-issuer "$AGLEDGER_SIGNER_OIDC_ISSUER" \
       "${image}@${RESOLVED_DIGEST}" >/dev/null 2>&1; then
    info "Image signature verified (keyless, public Rekor): ${image}@${RESOLVED_DIGEST}"
    return 0
  fi

  error "Image signature verification FAILED for ${image}@${RESOLVED_DIGEST}."
  error "This is NOT a genuine AGLedger release (tampered, swapped, or unsigned image)."
  error "Refusing to run it. Override for local/dev ONLY with: AGLEDGER_SKIP_VERIFY=true"
  return 1
}

# Verify a signed Helm OCI chart's keyless signature (cross-repo #667-C2).
# Same policy as verify_image. The chart ref is the OCI image form
# (registry-1.docker.io/agledger/agledger-chart:<version>).
verify_chart() {
  local chart_ref="$1"   # e.g. registry-1.docker.io/agledger/agledger-chart:1.0.3

  step "Verifying Helm chart signature"

  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    warn "AGLEDGER_SKIP_VERIFY=true — skipping chart signature verification (dev/local ONLY)."
    return 0
  fi
  if ! command -v cosign &>/dev/null; then
    if [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
      error "cosign not installed and AGLEDGER_REQUIRE_VERIFY=true. Install cosign 3.x."
      return 1
    fi
    warn "cosign not installed — cannot verify the chart signature before install."
    warn "Install cosign 3.x: https://docs.sigstore.dev/system_config/installation/"
    warn "Proceeding UNVERIFIED. Set AGLEDGER_REQUIRE_VERIFY=true to make this fatal."
    return 0
  fi

  if cosign verify \
       --certificate-identity-regexp "$AGLEDGER_SIGNER_IDENTITY_REGEXP" \
       --certificate-oidc-issuer "$AGLEDGER_SIGNER_OIDC_ISSUER" \
       "$chart_ref" >/dev/null 2>&1; then
    info "Chart signature verified (keyless, public Rekor): ${chart_ref}"
    return 0
  fi

  error "Chart signature verification FAILED for ${chart_ref}."
  error "Refusing to install an unverified chart. Override for dev ONLY with: AGLEDGER_SKIP_VERIFY=true"
  return 1
}

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
      # Validate the cached version still exists on Docker Hub before
      # returning it — a published-then-deleted tag (rare but real: v0.21.1
      # was pulled after F-447) leaves the cache pointing at a 404. Cheap
      # HEAD; on failure or non-404 fall through to the freshness query.
      local cached
      cached=$(cat "$cache_file")
      if [[ -n "$cached" ]]; then
        local tag_status
        # No -f: we want curl to surface 4xx via the captured %{http_code}
        # rather than exit non-zero (which would clobber the variable with the
        # || fallback). -sS keeps it quiet on success, surfaces real errors.
        tag_status=$(curl -sSL --max-time 5 -o /dev/null -w '%{http_code}' \
          "https://hub.docker.com/v2/repositories/agledger/agledger/tags/${cached}/" 2>/dev/null \
          || echo "000")
        if [[ "$tag_status" == "200" ]]; then
          echo "$cached"
          return 0
        fi
        if [[ "$tag_status" == "404" ]]; then
          echo "WARN: cached latest-version (${cached}) no longer exists on Docker Hub — refreshing." >&2
          rm -f "$cache_file"
        fi
        # Any other status (000 network, 5xx, etc): fall through to refresh,
        # but keep the cache file so the offline-fallback below still works.
      fi
    fi
  fi

  local api_url="https://hub.docker.com/v2/repositories/agledger/agledger/tags?page_size=100"
  local tags_json
  if tags_json=$(curl -fsSL --max-time 10 "$api_url" 2>/dev/null); then
    local latest
    latest=$(echo "$tags_json" \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort_semver \
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

# True when a connection string names the bundled postgres rather than an
# external host. Matches only exact bundled hostnames followed by a port number,
# which avoids false-positives on hosts like postgres-prod.rds.amazonaws.com.
# An empty URL is bundled: that is the default the compose files construct.
database_url_is_bundled() {
  local url="${1:-}"
  [[ -z "$url" ]] && return 0
  echo "$url" | grep -qE '@(postgres|localhost|127\.0\.0\.1):[0-9]'
}

# Detect whether DATABASE_URL points to the bundled postgres or an external host.
# Sets USES_BUNDLED_PG=true (bundled) or USES_BUNDLED_PG=false (external).
detect_db_mode() {
  if database_url_is_bundled "${DATABASE_URL:-}"; then
    USES_BUNDLED_PG=true
  else
    USES_BUNDLED_PG=false
  fi
}

# Build COMPOSE array with the correct -f flags for the current deployment.
# Uses bash arrays (not word-split strings) per project conventions.
# True when this install runs its containers with the OpenSSL FIPS provider
# active. Recorded in .env by `install.sh --fips` so it survives the process
# that set it: every script that brings containers up has to add the overlay,
# or a later `upgrade.sh` recreates them without OPENSSL_CONF and the host
# silently stops being FIPS. An ES256 key signs fine either way, so nothing
# else would surface the loss.
fips_overlay_enabled() {
  local value="${AGLEDGER_FIPS:-$(get_env_value AGLEDGER_FIPS "${COMPOSE_DIR}/.env")}"
  [[ "$value" == "true" ]]
}

build_compose_cmd() {
  local compose_file="${COMPOSE_DIR}/docker-compose.yml"
  local postgres_file="${COMPOSE_DIR}/docker-compose.postgres.yml"
  local prod_file="${COMPOSE_DIR}/docker-compose.prod.yml"
  local fips_file="${COMPOSE_DIR}/docker-compose.fips.yml"

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

  # Last, so its OPENSSL_CONF wins over anything an earlier overlay sets.
  if fips_overlay_enabled && [[ -f "${fips_file}" ]]; then
    COMPOSE+=(-f "${fips_file}")
  fi
}

# Verify a sibling container can actually reach Postgres on the compose network.
#
# Postgres's own healthcheck (`pg_isready`) runs INSIDE the postgres container,
# so it can pass while sibling-container reachability is broken — most commonly
# when Docker daemon iptables rules for the compose bridge are stale (FORWARD
# chain DROPs traffic between containers on the same bridge). Without this
# check, migrate hangs ~55s on a TCP timeout and the customer sees a confusing
# Node stack trace. With it, we fail fast and point at the canonical recovery.
#
# Bundled-PG only: skipped when DATABASE_URL points off-host (Aurora, RDS,
# managed PG), where the failure modes are different and the recovery is not
# "restart Docker."
#
# Requires: build_compose_cmd has run (so COMPOSE is set), images are pulled.
verify_sibling_reachability() {
  if [[ "${USES_BUNDLED_PG:-true}" != "true" ]]; then
    return 0
  fi
  # The agledger image ships no nc/pg_isready — node + net is the
  # only reliable TCP-probe primitive shipped in it. Using `compose run` against
  # the agledger-migrate service definition guarantees we hit the same network
  # path migrate itself will use moments later.
  local probe='const net=require("net");const s=net.createConnection({host:"postgres",port:5432,timeout:5000},()=>{s.end();process.exit(0);});s.on("error",e=>{console.error(e.code||e.message);process.exit(1);});s.on("timeout",()=>{console.error("ETIMEDOUT");process.exit(1);});'
  if "${COMPOSE[@]}" run --rm --no-deps --entrypoint /nodejs/bin/node agledger-migrate -e "$probe" >/dev/null 2>&1; then
    info "Sibling-container reachability: OK"
    return 0
  fi
  error "Postgres healthcheck passed, but a sibling container cannot reach it on the compose network."
  error "This is almost always Docker daemon iptables state — the FORWARD chain is dropping"
  error "container-to-container traffic on the compose bridge."
  error ""
  error "Recovery (recovers in seconds, no data loss):"
  error "  1. sudo systemctl restart docker"
  # Called from install.sh and upgrade.sh both, so it cannot name one of them.
  error "  2. Re-run this script."
  error ""
  error "If that doesn't help: 'sudo iptables -L FORWARD -n -v' should show DOCKER-FORWARD"
  error "before the default DROP policy. If not, file an issue at https://github.com/agledger-ai/install/issues"
  fatal "Aborting before migrations would hang on a TCP timeout."
}
