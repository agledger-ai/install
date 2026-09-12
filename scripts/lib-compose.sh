#!/usr/bin/env bash
# =============================================================================
# AGLedger — Shared Deployment Helpers
# =============================================================================
# Source this from scripts that need compose commands, logging, or ECR auth.
# Automatically resolves paths relative to this script's location.
# =============================================================================

# DEPLOY_DIR is the checkout root (the directory holding scripts/); REPO_ROOT is
# its PARENT, which is where support bundles and vault dumps land. Backups are
# NOT there: see backup_root below.
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
COMPOSE_DIR="${DEPLOY_DIR}/compose"

# Where this install's backup archives and its `.pre-upgrade-version` rollback
# marker live. Inside the checkout, because the checkout is what identifies one
# install: there is one `compose/.env` per checkout, and the backups belong to
# the database that .env names.
#
# It used to default to the checkout's PARENT, and the README's own two-stack
# recipe (`cp -r <this-install> ../agledger-2`) puts two checkouts in one
# parent. Both then wrote to one directory: `backup.sh --keep` in either deleted
# the other's pre-upgrade archive on retention, one `.pre-upgrade-version` named
# whichever install wrote it last, and two installs' tarballs were
# indistinguishable by name.
#
# BACKUP_DIR overrides it, which is what a mounted backup volume wants. Archive
# names carry the compose project name, so several installs can share one
# BACKUP_DIR without their retention sweeps reaching each other's files.
backup_root() {
  printf '%s' "${BACKUP_DIR:-${DEPLOY_DIR}/backup}"
}

# The location backups defaulted to in earlier releases.
legacy_backup_root() {
  printf '%s' "${REPO_ROOT}/backup"
}

# The rollback marker for THIS install: the file `upgrade.sh` writes naming the
# version to go back to.
#
# Named for the compose project, like the archives beside it, so two installs
# pointed at one BACKUP_DIR cannot overwrite each other's. The unscoped name is
# still read (below) because an install that upgraded before this carries one.
pre_upgrade_marker() {
  printf '%s/.pre-upgrade-version-%s' "$(backup_root)" "$(compose_project_name)"
}

# The version this install's marker names, or nothing. Reads the project-scoped
# file first and falls back to the unscoped one an earlier release wrote.
read_pre_upgrade_marker() {
  local candidate
  # Newest naming first, then the two places an install upgraded under an
  # earlier release could have left one. The legacy root is not optional: that
  # release wrote the marker to the checkout's PARENT, so an install that
  # upgraded before this one and rolls back after it finds its marker there and
  # nowhere else. Leaving it out made the fallback dead in exactly the case it
  # was written for, and a rollback then printed no version to return to.
  for candidate in \
    "$(pre_upgrade_marker)" \
    "$(backup_root)/.pre-upgrade-version" \
    "$(legacy_backup_root)/.pre-upgrade-version"; do
    if [[ -f "$candidate" ]]; then
      head -1 "$candidate"
      return 0
    fi
  done
}

# Say so when the older location still holds archives or a rollback marker.
#
# Nothing is moved. On a host running two stacks that directory holds both
# installs' archives under names that do not say which is which, so only the
# operator can decide; a script that guessed would be doing the thing this
# whole change exists to stop.
report_legacy_backup_root() {
  local legacy current found
  legacy="$(legacy_backup_root)"
  current="$(backup_root)"
  [[ "$legacy" != "$current" ]] || return 0
  [[ -d "$legacy" ]] || return 0
  # `|| true` is load-bearing under `set -euo pipefail`. An install run with
  # sudo leaves that directory root-owned, an operator who hardens it (it holds
  # full database dumps) makes it unreadable to the cron user, and `find` then
  # exits non-zero with its message already sent to /dev/null: the substitution
  # carries that status out and kills the caller with nothing printed at all.
  # `backup.sh` and `restore.sh` both call this before they do any work, so the
  # nightly backup and the 3am restore would end on a blank screen.
  found="$(find "$legacy" -maxdepth 1 \( -name 'backup-*.tar.gz' -o -name '.pre-upgrade-version' \) 2>/dev/null | head -1 || true)"
  [[ -n "$found" ]] || return 0
  warn "Older backups are in ${legacy}, the directory this defaulted to in earlier releases."
  warn "  This install now uses ${current}. Nothing was moved: on a host running two stacks"
  warn "  that directory holds both installs' archives, and only you know which are this one's."
  warn "  Restore an older archive by path, or set BACKUP_DIR=${legacy} to keep writing there."
}

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

# Escape a value for the REPLACEMENT half of `sed s|...|...|`.
#
# Three characters are read specially there and every one of them is reachable
# from a real .env value: `&` is the whole match (a DATABASE_URL query string
# carries one), `|` closes the expression, and `\` escapes whatever follows.
# Unescaped, the write does not fail, it writes a DIFFERENT value than the
# caller asked for, which is the worst shape for a config file nothing reads
# back. Backslash first, or it would escape the escapes added after it.
sed_replacement_escape() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}

# Set KEY=VALUE in an env file: replace the line if KEY exists, append if not.
# Usage: upsert_env_var KEY VALUE FILE
#
# The pattern matches the same shapes `get_env_value` reads and `delete_env_var`
# removes, and the replacement keeps whatever prefix it found. `^KEY=` alone
# walked past `export KEY=old` and appended a second, plain assignment below it,
# leaving one file naming two values for one key: after a rollback the first
# line an operator reads names the release they just left.
upsert_env_var() {
  local key="$1" value="$2" file="$3"
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file"; then
    sedi -E "s|^([[:space:]]*(export[[:space:]]+)?)${key}[[:space:]]*=.*|\1${key}=$(sed_replacement_escape "$value")|" "$file"
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
# against values like "true" (.env.example ships trailing comments).
# Returns empty string if the key is absent.
# Usage: VALUE=$(get_env_value KEY FILE)
# Which version an install.sh run should use, and where that came from.
# Echoes "<version>|<source>", source one of: requested, installed, ambiguous,
# latest. An empty version with source `latest` means "go ask Docker Hub".
# Source `ambiguous` carries the recorded (non-concrete) tag as its version
# half; the caller refuses rather than adopting it.
#
# A version, like a registry, names an install for its life and not for one
# process, so a run that passes no --version adopts what the last install
# wrote and re-running the installer is idempotent. Resolving latest here
# instead would make the flagless re-run a version change: it would rewrite
# AGLEDGER_VERSION, re-pin the digest and apply migrations, with no backup taken
# and without the word "upgrade" anywhere in the output. Moving between releases
# is upgrade.sh's job, because upgrade.sh backs up first and writes
# backup/.pre-upgrade-version, the one file that says what to roll back to.
#
# Adopting the recorded version requires it to actually BE a version, for the
# same reason: a non-concrete tag with real install state is not safe to
# resolve either way. Falling through to Docker Hub's latest (the old
# behaviour) silently moves an install pinned to a testbed build, an air-gap
# mirror tag, or the .env.example `latest` placeholder never overwritten.
# Adopting it as-is would be just as wrong the other way: it is not
# necessarily a deliberate pin, so treating it as one and skipping resolution
# entirely could leave a first, still-placeholder install stuck on `latest`
# forever. Neither guess is safe, so this is the one case that refuses.
#
# Extracted so the guards can drive every case with no network and no daemon.
install_version_decision() {
  local requested="$1" installed="$2" has_install_state="${3:-false}"
  if [[ -n "$requested" ]]; then
    printf '%s|requested' "$requested"
    return 0
  fi
  # Two things have to be true before a recorded version is adopted, and each
  # covers a case the other does not.
  #
  # `has_install_state` (env_file_carries_install_state: a PLATFORM_API_KEY or
  # VAULT_SIGNING_KEY, which only a completed install writes) separates a real
  # install from a .env that merely exists. install.sh copies .env.example over
  # early and does not write the concrete version until much later, so every
  # fatal in between leaves a file that looks installed and is not.
  #
  # The version also has to BE a version. .env.example ships the placeholder
  # `AGLEDGER_VERSION=latest`, which the documented external-database onramp
  # tells an operator to copy and edit before the first install. Adopting it
  # would pin the install to a floating tag and record it: upgrade.sh then reads
  # `latest` as CURRENT_VERSION and writes it into backup/.pre-upgrade-version,
  # so the one file that says what to roll back to names the image you just
  # upgraded to. A tag that is not a release number falls through to Docker Hub
  # instead, which is what a first install should do.
  if [[ "$has_install_state" == "true" ]]; then
    if is_concrete_version "$installed"; then
      printf '%s|installed' "$installed"
      return 0
    fi
    # Real install state exists, but the recorded tag is not shaped like a
    # release number: a testbed build, an air-gap mirror tag, `edge`, or the
    # .env.example `latest` placeholder never overwritten. A plain re-run
    # cannot tell a deliberate pin from that placeholder, so it must not fall
    # through to Docker Hub's latest and move the install with no backup, no
    # rollback marker and no warning. The caller refuses and names both ways
    # forward: re-run with --version to stay, or upgrade.sh to move.
    printf '%s|ambiguous' "$installed"
    return 0
  fi
  printf '|latest'
}

# True for something shaped like a release number (`1.4.0`, `v1.4.0`,
# `1.4.0-rc.1`), false for a floating tag (`latest`, `stable`, `main`, `edge`)
# or an empty value. Deliberately a shape test rather than a deny-list: a tag
# nobody has thought of yet is still not a version to pin an install to.
is_concrete_version() {
  [[ "${1#v}" =~ ^[0-9] ]]
}

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
  #
  # The decode itself is `dotenv_decode_value`, shared with `load_env` and with
  # the file `docker run --env-file` is handed, so all three readers of one
  # `.env` resolve a value to the same string.
  local raw
  raw=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" 2>/dev/null | tail -1 || true)
  [[ -n "$raw" ]] || return 0
  dotenv_decode_value "${raw#*=}"
}

# Decode the text to the right of the `=` in one env-file assignment, printing
# what docker-compose's dotenv parser would hand a container.
#
# Three readers used to decode one file three different ways, and the three
# disagreed on any `DATABASE_URL` carrying more than one query parameter --
# which the pg driver's own startup warning tells operators to write, and which
# `connect_timeout` or `application_name` produce too:
#
#   DATABASE_URL=...?sslmode=require&uselibpqcompat=true
#     `source .env` read this as UNSET, because `&` backgrounds the assignment.
#   DATABASE_URL="...?sslmode=require&uselibpqcompat=true"
#     `docker run --env-file` read this WITH its quotes, because --env-file is
#     not a dotenv parser: it splits on the first `=` and takes the rest
#     literally.
#
# There was no third form that worked everywhere, and neither failure named
# itself: the bare form made `detect_db_mode` report bundled and backup.sh dump
# an empty container while the install served Aurora, and the quoted form ended
# the install "installed, but NOT usable (no platform API key)".
#
# Quoting rules, matching compose: inside quotes the value ends at the closing
# quote and the rest of the line is a comment, so `#` is ordinary text there.
# Unquoted, a comment starts at whitespace + `#`, and surrounding whitespace is
# not part of the value. Internal whitespace IS part of it (`ORG_NAME=Acme Corp`).
dotenv_decode_value() {
  local v="$1" body
  # Whitespace around the `=` (`KEY = v`, from hand-editing) is not the value.
  while [[ "$v" == [[:space:]]* ]]; do v="${v#[[:space:]]}"; done

  if [[ "$v" == '"'* ]]; then
    body="${v#\"}"
    if [[ "$body" == *'"'* ]]; then
      printf '%s' "${body%%\"*}"
      return 0
    fi
  elif [[ "$v" == "'"* ]]; then
    body="${v#\'}"
    if [[ "$body" == *"'"* ]]; then
      printf '%s' "${body%%\'*}"
      return 0
    fi
  fi

  # Unquoted (or an unterminated quote, which compose also treats as literal).
  v=$(printf '%s' "$v" | sed -E 's|[[:space:]]+#.*$||')
  while [[ "$v" == *[[:space:]] ]]; do v="${v%[[:space:]]}"; done
  printf '%s' "$v"
}

# Every assignment SRC makes, decoded, written to DST as bare `KEY=value` --
# no `export`, no quotes, no inline comments, one line each.
#
# This is the only form `docker run --env-file` reads the way compose does.
# Handing it the operator's `.env` verbatim is what made `mint_platform_key`
# pass a quoted URL through with its quotes still attached, so init dialled a
# host named `"postgresql:` and the install ended with no credential.
dotenv_normalize_file() {
  local src="$1" dst="$2" line key
  : > "$dst"
  [[ -f "$src" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    key="${BASH_REMATCH[2]}"
    printf '%s=%s\n' "$key" "$(dotenv_decode_value "${line#*=}")" >> "$dst"
  done < "$src"
}

# True when FILE puts CONTENT on the right of `DATABASE_URL=`. The question
# `detect_db_mode` needs is "does this install declare a database", which is
# not the same as "can this reader make a value out of it" -- that difference
# is exactly the case it must refuse to guess through.
#
# Quotes, whitespace and an inline comment are not content, so the deliberate
# `DATABASE_URL=""` an operator writes for "bundled" answers no rather than
# tripping the refusal.
env_file_declares_database_url() {
  local file="${1:-}" raw
  [[ -f "$file" ]] || return 1
  raw=$(grep -E "^[[:space:]]*(export[[:space:]]+)?DATABASE_URL[[:space:]]*=" "$file" 2>/dev/null | tail -1 || true)
  [[ -n "$raw" ]] || return 1
  raw=$(printf '%s' "${raw#*=}" | tr -d "[:space:]\"'" | sed -E 's|#.*$||')
  [[ -n "$raw" ]]
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
# Echoes one of:
#
#   (nothing)                     AGLEDGER_INSTANCE_ID already holds a UUID.
#   generate                      no usable id anywhere in the file, mint one.
#   adopt-legacy-org-id:<uuid>    AGLEDGER_INSTANCE_ID is unset or empty, but
#                                 the retired AGLEDGER_ORGANIZATION_ID fallback
#                                 is itself a UUID. Earlier releases read that
#                                 value as the hub id when no instance id was
#                                 set, so any federating Server provisioned
#                                 that way has peers who stored it. Carry it
#                                 into AGLEDGER_INSTANCE_ID
#                                 verbatim rather than minting a new one.
#
# The "already a UUID" case is the important half. Writing a fresh id over a
# Server that already has a usable one would change the identity its peers
# have stored and 401 every message after the next restart. There is no such
# hazard in the other direction: a Server whose id is absent or is the old
# literal "default" cannot have completed a handshake, because the peer's
# schema declares `peerHubId` as `format: uuid` and refuses it.
#
# The adopt case only fires when AGLEDGER_INSTANCE_ID is unset or empty, not
# when it holds other non-UUID junk (a stale "default" or hand-typed label):
# that value was written by this installer or an operator, not inherited from
# the retired fallback, so it carries no hint that a peer stored the org id.
federation_hub_id_action() {
  local file="$1" instance_id org_id
  instance_id="$(get_env_value AGLEDGER_INSTANCE_ID "$file")"
  is_uuid "$instance_id" && return 0
  if [[ -z "$instance_id" ]]; then
    org_id="$(get_env_value AGLEDGER_ORGANIZATION_ID "$file")"
    if is_uuid "$org_id"; then
      echo "adopt-legacy-org-id:${org_id}"
      return 0
    fi
  fi
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
# one per install run. This reports the whole set at once, on the host,
# before the pull.
#
# Prints one gap per line: a headline, then remedy lines indented four spaces.
# Empty output means nothing is missing. Mirrors the `if (isProd)` block in
# the Server's config loader; the two are kept in step by hand.
#
# Usage: while IFS= read -r gap; do ...; done < <(missing_prod_config FILE)
missing_prod_config() {
  local file="$1" db_url node_env
  # Every gate below is scoped to production, exactly as the config loader scopes them.
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
  # from POSTGRES_* at container start, and the config loader skips the check when the
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

# --- External database: credentials, and a client old enough to refuse ---

# Percent-decode one URI component.
urldecode() {
  local s="${1//+/ }"
  case "$s" in
    *%*) printf '%b' "${s//%/\\x}" ;;
    *)   printf '%s' "$s" ;;
  esac
}

# Decompose a postgres:// URL into the PG* environment variables libpq reads,
# and export them.
#
# Every psql/pg_dump/pg_restore call on the external-database path used to take
# the URL as an argument, which puts the password in the process's argv where
# `ps` and /proc show it to every local user on the box. Backups run on a
# schedule, and the external-database branch is exactly the one whose URL holds
# a real managed-database password, so a scheduled backup re-exposes it on
# every run.
#
# It also fixes a second thing. `psql URL -d postgres` does not connect to the
# maintenance database on that server: psql takes positionals as [dbname
# [username]], so with -d supplying the dbname the URL is consumed as a
# *username* and host, port and password fall back to libpq defaults. Once the
# connection lives in the environment, `-d postgres` means what it reads as.
#
# Usage: pg_env_from_url "$DATABASE_URL"   (exports; call in a subshell to scope)
pg_env_from_url() {
  local url="$1"
  [[ "$url" == postgres://* || "$url" == postgresql://* ]] \
    || { echo "Not a postgres URL: ${url%%://*}://..." >&2; return 1; }

  local rest="${url#*://}" query="" userinfo="" hostport="" db=""
  case "$rest" in *\?*) query="${rest#*\?}"; rest="${rest%%\?*}" ;; esac
  # Split on the LAST @: a password may legally contain ':' but an unencoded
  # '@' is not legal in userinfo, so the last one is the delimiter.
  case "$rest" in *@*) userinfo="${rest%@*}"; rest="${rest##*@}" ;; esac
  hostport="${rest%%/*}"
  case "$rest" in */*) db="${rest#*/}" ;; esac

  local user="${userinfo%%:*}" pass=""
  case "$userinfo" in *:*) pass="${userinfo#*:}" ;; esac

  local host="${hostport%%:*}" port=""
  case "$hostport" in *:*) port="${hostport##*:}" ;; esac

  PGHOST="$(urldecode "${host:-localhost}")"
  export PGHOST
  [[ -n "$port" ]] && export PGPORT="$port"
  if [[ -n "$user" ]]; then PGUSER="$(urldecode "$user")"; export PGUSER; fi
  if [[ -n "$pass" ]]; then PGPASSWORD="$(urldecode "$pass")"; export PGPASSWORD; fi
  if [[ -n "$db" ]]; then PGDATABASE="$(urldecode "$db")"; export PGDATABASE; fi

  # The two query parameters a managed database actually needs. Anything else
  # in the query string is left behind rather than guessed at.
  local param
  for param in sslmode sslrootcert; do
    case "&${query}" in
      *"&${param}="*|*"?${param}="*)
        local value="${query##*"${param}"=}"
        value="${value%%&*}"
        case "$param" in
          sslmode)     PGSSLMODE="$(urldecode "$value")"; export PGSSLMODE ;;
          sslrootcert) PGSSLROOTCERT="$(urldecode "$value")"; export PGSSLROOTCERT ;;
        esac
        ;;
    esac
  done
}

# psql used only to ASK the server its version. Unlike pg_dump/pg_restore,
# psql does not refuse a version it does not match, so any recent one answers
# and this needs no host client installed. Same image the bundled database
# uses, so nothing new is pinned.
PG_QUERY_IMAGE="${PG_QUERY_IMAGE:-postgres:18-alpine}"

# Major version of the server the PG* environment points at, or nothing.
pg_server_major() {
  local num=""
  if command -v psql >/dev/null 2>&1; then
    num="$(psql -tAc 'SHOW server_version_num' 2>/dev/null | tr -d '[:space:]')"
  elif command -v docker >/dev/null 2>&1; then
    local net=()
    case "${PGHOST:-}" in localhost|127.0.0.1|::1|"") net=(--network host) ;; esac
    num="$(docker run --rm \
      -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
      "${net[@]}" "$PG_QUERY_IMAGE" psql -tAc 'SHOW server_version_num' 2>/dev/null | tr -d '[:space:]')"
  fi
  [[ "$num" =~ ^[0-9]+$ ]] || return 1
  echo $(( num / 10000 ))
}

# Major version of a local client binary (pg_dump, psql, pg_restore).
pg_client_major() {
  local out
  out="$("$1" --version 2>/dev/null)" || return 1
  # "pg_dump (PostgreSQL) 16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)" -> 16.
  # The first number in the line is the version on every packaging of these
  # tools; the distro suffix that follows also carries digits, so take the
  # first match rather than the last.
  [[ "$out" =~ ([0-9]+) ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# Run a pg client tool against the external database with a version that the
# server will accept.
#
# pg_dump refuses to dump a server newer than itself, and the host client is
# routinely older than the server: this product ships PostgreSQL 18 and is
# validated against Aurora 18, while Ubuntu 24.04 (a platform install.sh
# recognises by name in its own preflight) carries client 16 in the default
# repos. Without this, the default outcome on a supported host is no backup
# at all.
#
# Prefer the host binary when it is new enough. Otherwise run the matching
# client from a container, which needs no new pin because the version comes
# from the server itself. Credentials pass as environment names only, never as
# arguments.
#
# Usage: pg_client_run pg_dump -Fc          (stdout is the tool's stdout)
pg_client_run() {
  local tool="$1"; shift
  local server_major client_major
  server_major="$(pg_server_major || true)"
  client_major="$(command -v "$tool" >/dev/null 2>&1 && pg_client_major "$tool" || true)"

  if [[ -n "$client_major" && ( -z "$server_major" || "$client_major" -ge "$server_major" ) ]]; then
    "$tool" "$@"
    return
  fi

  if [[ -z "$server_major" ]]; then
    fatal "Cannot reach the database to check its version, and no ${tool} is installed. Check DATABASE_URL and network reachability." >&2
  fi

  # Every notice this function emits goes to stderr, without exception. Its
  # stdout is the tool's stdout and callers redirect it into the artifact
  # (`pg_client_run pg_dump -Fc > db.dump`), so a status line written to stdout
  # is not a status line: it is 118 bytes in front of PGDMP, and the dump it
  # prefixes is unreadable by pg_restore while the backup still reports success.
  if [[ -n "$client_major" ]]; then
    info "Host ${tool} is ${client_major}; the server is ${server_major}. Using a matching client from a container." >&2
  else
    info "No ${tool} on this host. Using a PostgreSQL ${server_major} client from a container." >&2
  fi

  command -v docker >/dev/null 2>&1 || fatal >&2 \
    "Need a PostgreSQL ${server_major} ${tool} and this host has $([[ -n "$client_major" ]] && echo "only ${client_major}" || echo "none"), with no docker to fall back on.
  Install matching client tools, e.g. on Debian/Ubuntu:
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo \"deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt \$(lsb_release -cs)-pgdg main\" | sudo tee /etc/apt/sources.list.d/pgdg.list
    sudo apt-get update && sudo apt-get install -y postgresql-client-${server_major}"

  # A host-local database is not reachable from inside a container's own
  # network namespace, so join the host's. (Linux; on macOS set PGHOST to
  # host.docker.internal instead.)
  local net=()
  case "$PGHOST" in
    localhost|127.0.0.1|::1|"") net=(--network host) ;;
  esac

  docker run --rm -i \
    -e PGHOST -e PGPORT -e PGUSER -e PGPASSWORD -e PGDATABASE -e PGSSLMODE \
    "${net[@]}" "postgres:${server_major}-alpine" "$tool" "$@"
}

# Do two connection endpoints name the same PostgreSQL server?
#
# Asked because a restore reads one URL and writes another: the backup comes
# from DATABASE_URL and the DROP is issued on DATABASE_URL_MIGRATE. The database
# NAME matches by accident on every install (the engine's default is `agledger`
# everywhere), so the name is not the part worth comparing — the host is.
#
# An omitted port is 5432, and the loopback spellings are one host: those are
# the two ways two identical endpoints are written differently, and a false
# refusal here stops a restore that should run.
#
# Usage: pg_endpoints_match "$host_a" "$port_a" "$host_b" "$port_b"
pg_endpoints_match() {
  local host_a="$1" port_a="${2:-5432}" host_b="$3" port_b="${4:-5432}"
  [[ -n "$port_a" ]] || port_a=5432
  [[ -n "$port_b" ]] || port_b=5432
  case "$host_a" in localhost|127.0.0.1|::1|"") host_a=localhost ;; esac
  case "$host_b" in localhost|127.0.0.1|::1|"") host_b=localhost ;; esac
  [[ "$host_a" == "$host_b" && "$port_a" == "$port_b" ]]
}

# Is this file a PostgreSQL custom-format archive?
#
# A backup that cannot be read is worth nothing, and the two ways this file has
# been wrong are both silent: a status line written ahead of the archive (the
# dump body is intact and pg_restore refuses the whole file), and a dump that
# produced no bytes at all. Both leave a plausible-looking tarball behind and
# both are only discovered by the restore, which by then has already dropped
# the database.
#
# `PGDMP` is the magic at offset 0 of every custom-format archive, so this needs
# no client, no server and no container, and it names WHICH way the file is
# wrong. Callers pair it with the deeper check they can afford.
#
# Usage: pg_dump_magic_ok /path/to/db.dump
pg_dump_magic_ok() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  [[ "$(head -c 5 "$file" 2>/dev/null)" == "PGDMP" ]]
}

# What is in front of the archive, for an operator who has to act on it.
# Prints the first line, truncated; empty when the file is empty.
pg_dump_prefix_hint() {
  head -c 200 "$1" 2>/dev/null | head -1 | tr -d '\0'
}

# --- The audit-chain event trigger ---
#
# The baseline schema installs `agledger_block_audit_drop`, an sql_drop event
# trigger that is layer 2 of the tamper model, the DDL guard: it blocks in-band
# DROP of `audit_vault`, its partitions, the four `org_admin_read*` tables and
# `vault_signing_keys`. CREATE EVENT TRIGGER is superuser-only, and
# a managed database hands you an owner role with CREATEDB and not that, which
# is the default shape on Aurora, RDS, Cloud SQL and Azure Database. So every
# script that rebuilds this schema has to ask the question BEFORE it does
# anything it cannot take back.
#
# One predicate, one verdict, one remedy, shared by install.sh (which asks
# before it installs) and restore.sh (which asks before it drops the database).
# They were separate and only install.sh asked, so a restore discovered it from
# inside pg_restore, with the database already dropped.

# The privilege probe, for the CONNECTED role: superuser, or a member of the
# superuser-equivalent role each managed provider substitutes for it.
#
# A bare boolean EXPRESSION, deliberately: no leading SELECT, no trailing
# semicolon. The two callers need it in different positions, and a fragment is
# the only form that composes into both. restore.sh wraps it in a SELECT of its
# own and feeds that to `psql -tA`, which answers `t`/`f`; install.sh drops it
# into a select list that already opened with `SELECT current_user AS who,` and
# reads the column through node. Shipping the SELECT inside the variable made
# install.sh's query `SELECT current_user AS who, SELECT COALESCE(...)`, which
# is a syntax error, and because the probe's failure is swallowed by `|| true`
# the gate degraded from a refusal to a warning on every external install.
# audit_event_trigger_probe_sql() is the standalone form; use it rather than
# prepending SELECT by hand.
# shellcheck disable=SC2034  # read by install.sh and restore.sh, which source this file
AUDIT_EVENT_TRIGGER_PREDICATE="COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false)
    OR COALESCE((SELECT bool_or(pg_has_role(current_user, oid, 'MEMBER')) FROM pg_roles
                  WHERE rolname IN ('rds_superuser','cloudsqlsuperuser','azure_pg_admin')), false)"

# The standalone statement, for a caller that wants the answer on its own.
audit_event_trigger_probe_sql() {
  printf 'SELECT %s;\n' "${AUDIT_EVENT_TRIGGER_PREDICATE}"
}

# Classify a probe answer. Three verdicts, not two: "answered no" and "could not
# ask" are different, and only the first is worth refusing on. A probe that
# never ran — a connection reset during the failover a restore happens in, a
# role that cannot read pg_roles — must not read as permission granted, and
# must not read as permission denied either. Same reason the DB_PRESENT probe
# in restore.sh keeps its own failure separate from its answer.
#
# Takes the raw probe output, because the two producers spell it differently:
# psql -tA prints `t`/`f`, the node probe prints `PRIV=true`/`PRIV=false`.
#
# Usage: verdict=$(audit_event_trigger_verdict "$probe_output")   # ok|refuse|unknown
audit_event_trigger_verdict() {
  local out="$1"
  # Anchored to line start, which is what install.sh's grep did before this was
  # a function. Unanchored, a probe that failed while echoing its own query back
  # ("... WHERE PRIV=true ...") would read as a granted privilege, and on
  # restore.sh that answer drops a database.
  # A here-string, NOT `printf ... | grep -q`. Both callers run with
  # `set -o pipefail`, and `grep -q` exits on the first match: once the probe
  # output is bigger than a pipe buffer, printf's next write takes EPIPE, the
  # pipeline reports 141, and a real answer on line 1 reads as no-match. That
  # turns install.sh's `fatal` into a warn-and-continue on exactly the roles the
  # gate exists to stop. Measured: correct up to ~100 KB, wrong 10 times out of
  # 10 at 500 KB.
  if grep -q '^PRIV=true' <<<"$out"; then echo ok; return 0; fi
  if grep -q '^PRIV=false' <<<"$out"; then echo refuse; return 0; fi
  out="$(printf '%s' "$out" | tr -d '[:space:]')"
  case "$out" in
    t|true|TRUE)   echo ok ;;
    f|false|FALSE) echo refuse ;;
    *)             echo unknown ;;
  esac
}

# The remedy, one copy. Printed with no logger prefix so each caller can pipe it
# through its own (install.sh has `error`, restore.sh has `log`).
audit_event_trigger_remedy() {
  local role="${1:-<migrate role>}"
  cat <<REMEDY
The schema installs 'agledger_block_audit_drop', which protects the audit chain, and
CREATE EVENT TRIGGER is superuser-only. Grant by provider:
  Amazon RDS / Aurora   GRANT rds_superuser TO ${role};
  Google Cloud SQL      GRANT cloudsqlsuperuser TO ${role};
  Azure Database        GRANT azure_pg_admin TO ${role};
  Self-managed          ALTER ROLE ${role} SUPERUSER;   (or run migrations as one)
REMEDY
}

# Is the trigger actually on the database? Asked AFTER a restore, because
# pg_restore does not stop on a statement it cannot run: a refused CREATE EVENT
# TRIGGER is reported among its own "errors ignored on restore" and the rows all
# land anyway. That is the one outcome where the data looks complete and a layer
# of the tamper model is missing, and nothing outside pg_restore's stderr said so.
# shellcheck disable=SC2034  # read by install.sh and restore.sh, which source this file
AUDIT_EVENT_TRIGGER_PRESENT_SQL="SELECT count(*) FROM pg_event_trigger WHERE evtname = 'agledger_block_audit_drop';"

# The DDL that puts it back, and the whole repair: the function it calls is an
# ordinary function that a non-superuser restores fine, so only the trigger
# itself is ever the missing half.
# shellcheck disable=SC2034  # read by install.sh and restore.sh, which source this file
AUDIT_EVENT_TRIGGER_DDL="CREATE EVENT TRIGGER agledger_block_audit_drop ON sql_drop
   EXECUTE FUNCTION public.agledger_block_audit_drop();"

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
  # docker COLLAPSES contiguous published ports into a single range
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
# `install.sh` persists COMPOSE_PROFILES=monitoring so later compose
# commands keep the profile, but an install predating that has no such line.
# `upgrade.sh` then ran `up -d` with the profile unselected: compose left the
# monitoring containers running, untouched, on their old image and old port
# bindings, while reporting a successful upgrade. The containers themselves are
# the only honest answer to "is monitoring part of this install", so ask them.
#
# The listing is captured first and matched with a here-string, the way
# `audit_event_trigger_verdict` is and for the same reason: every caller runs
# with `set -o pipefail`, `grep -q` exits on the first match, and once the
# producer's output outgrows a pipe buffer its next write takes EPIPE and the
# pipeline reports failure. Here that reads as "monitoring is not running" on a
# host where it is, which silently skips the profile repair.
monitoring_containers_running() {
  local project services
  project="$(compose_project_name)"
  services="$(docker ps --filter "label=com.docker.compose.project=${project}" \
    --format '{{.Label "com.docker.compose.service"}}' 2>/dev/null || true)"
  [[ -n "$services" ]] || return 1
  grep -qxE "$(printf '%s' "$MONITORING_SERVICES" | tr ' ' '|')" <<< "$services"
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

# Repair the .env properties an install can be missing regardless of which
# version it is on. Sets ENV_RECONCILED=true when it wrote anything and
# MONITORING_ACTIVE to whether this host is running the monitoring stack.
#
# Shared by upgrade.sh and restore.sh because both start a stack out of a file
# they did not write. None of these gaps is a property of a version gap: a
# missing or stale COMPOSE_FILE line, an absent federation identity, an absent metrics
# scrape token and an unselected monitoring profile are properties of the .env,
# so an install already on the target version needs each repair as much as one
# that is behind, and a DR restore onto a host whose .env predates them needs
# them before anything comes up rather than after.
#
# That case is routine rather than theoretical, because these scripts never
# update themselves. Only the image is pulled, so a machine that upgraded ran
# whatever upgrade.sh its checkout held, which may carry none of these; the
# operator's remedy is to refresh the install scripts and re-run. All of them
# are idempotent: each writes only when the value is absent, so a re-run on a
# reconciled .env changes nothing and leaves ENV_RECONCILED false.
#
# build_overlay_list reads USES_BUNDLED_PG, so detect_db_mode runs before the
# comparison rather than being assumed; it is idempotent, and callers that run
# it themselves are unaffected.
reconcile_env_file() {
  local env_file="$1"
  # Both are this function's OUTPUT, read by upgrade.sh and restore.sh, which
  # source this file.
  # shellcheck disable=SC2034
  ENV_RECONCILED=false
  # shellcheck disable=SC2034
  MONITORING_ACTIVE=false
  # Repair, never create. upsert_env_var appends to a file it cannot read, so
  # without this a caller pointed at a checkout that was never installed would
  # get a two-line .env conjured out of nothing and every reader downstream
  # would treat it as an install.
  [[ -f "$env_file" ]] || return 0

  # Absent OR stale. It used to be absent-only, which was enough while the list
  # was derived from files this repo ships. It is not enough now that it can
  # carry the operator's own override file: adding or deleting that file changes
  # the correct list, and a `.env` still naming the old one sends every manual
  # `docker compose` from compose/ to a different stack than the scripts bring
  # up, or, after a deletion, to a file that is not there. install.sh already
  # rewrites this key on every run; upgrade.sh and restore.sh reach the same
  # answer through here.
  local current_compose_file
  current_compose_file="$(get_env_value COMPOSE_FILE "$env_file")"
  detect_db_mode
  build_overlay_list
  if [[ "$current_compose_file" != "$OVERLAY_LIST" ]]; then
    if [[ -z "$current_compose_file" ]]; then
      warn "COMPOSE_FILE not persisted in .env: manual 'docker compose' commands will drop overlays."
      warn "Auto-adding based on current deployment."
    fi
    upsert_env_var COMPOSE_FILE "${OVERLAY_LIST}" "$env_file"
    ENV_RECONCILED=true
    info "Set COMPOSE_FILE=${OVERLAY_LIST}"
  fi

  # --- Federation Identity ---
  # An install stood up before install.sh generated one has no
  # AGLEDGER_INSTANCE_ID, so its operator is told the Server's id is the literal
  # "default" and the peer's handshake refuses it. `federation_hub_id_action`
  # will not touch a Server that already has a usable id, so this can never move
  # an identity peers have stored: it only fills in the absent case.
  local hub_id_action hub_id_value
  hub_id_action="$(federation_hub_id_action "$env_file")"
  case "$hub_id_action" in
    generate)
      if hub_id_value=$(generate_uuid); then
        upsert_env_var AGLEDGER_INSTANCE_ID "${hub_id_value}" "$env_file"
        ENV_RECONCILED=true
        info "Generated AGLEDGER_INSTANCE_ID (this Server's federation identity; it had none)"
      else
        warn "Could not generate AGLEDGER_INSTANCE_ID. Federation stays unavailable until one is set;"
        warn "GET /federation/v1/admin/instance names the variable and how to generate a value."
      fi
      ;;
    adopt-legacy-org-id:*)
      # The retired AGLEDGER_ORGANIZATION_ID fallback was this Server's identity
      # and peers hold it. Carry it forward rather than mint a new one, which
      # would 401 every message after restart.
      upsert_env_var AGLEDGER_INSTANCE_ID "${hub_id_action#adopt-legacy-org-id:}" "$env_file"
      ENV_RECONCILED=true
      info "Adopted AGLEDGER_ORGANIZATION_ID as AGLEDGER_INSTANCE_ID (the identity peers already hold); AGLEDGER_ORGANIZATION_ID can be deleted from .env"
      ;;
  esac

  # --- Metrics scrape token ---
  # An install stood up before /metrics was gated has no METRICS_AUTH_TOKEN, and
  # .env sets NODE_ENV=production, so the endpoint answers the API-key chain and
  # a Prometheus that holds no credential simply stops collecting, silently.
  # Never regenerated: a token already in .env is the one the running Prometheus
  # was configured with.
  local metrics_token_value
  if [[ -z "$(get_env_value METRICS_AUTH_TOKEN "$env_file")" ]]; then
    if metrics_token_value=$(openssl rand -hex 24); then
      upsert_env_var METRICS_AUTH_TOKEN "${metrics_token_value}" "$env_file"
      ENV_RECONCILED=true
      info "Generated METRICS_AUTH_TOKEN (bearer token for /metrics; it had none)"
    else
      warn "Could not generate METRICS_AUTH_TOKEN. /metrics answers the API-key chain under"
      warn "NODE_ENV=production, so a scrape holding no credential will report the target down."
    fi
  fi

  # --- Monitoring Profile ---
  # An install stood up with --with-monitoring before COMPOSE_PROFILES was
  # persisted has monitoring containers running and nothing in .env that selects
  # them. Every later compose command, `up -d` included, then skips the profile:
  # the containers keep running on the OLD image with the OLD port bindings
  # while the run reports success. Repair the .env before anything else reads
  # it, so the profile also sticks for the operator's own later commands.
  if monitoring_containers_running; then
    # shellcheck disable=SC2034  # output; see the declaration above
    MONITORING_ACTIVE=true
    if [[ "$(ensure_monitoring_profile "$env_file")" == "added" ]]; then
      # shellcheck disable=SC2034  # output; see the declaration above
      ENV_RECONCILED=true
      info "Monitoring containers are running but COMPOSE_PROFILES did not select them."
      info "  Added COMPOSE_PROFILES=monitoring to .env so this run includes them."
    fi
  fi
}

# True when the API container answers its own readiness probe.
#
# The question is "is this stack actually serving", and `compose ps` answers
# neither half of it: a container can be up and not serving (an unhealthy one
# reports `running`, a config fail-fast crashloop reports `restarting`), which
# is exactly the state a failed `up -d --wait` leaves behind.
#
# /health/ready, not /health, and the same endpoint the compose healthcheck and
# the image HEALTHCHECK use. `/health` is a static 200 that opens no connection,
# so a container pointed at a database that is down, gone or refusing its
# credentials answers it: an upgrade whose restart failed on exactly that would
# read as "already serving" and be reported as nothing to do. The readiness
# handler runs SELECT 1 and answers 503 when it cannot.
#
# Requires: build_compose_cmd has run, so COMPOSE is set.
api_service_serving() {
  "${COMPOSE[@]}" exec -T agledger-api /nodejs/bin/node -e \
    "fetch('http://localhost:3000/health/ready').then(r=>r.ok?process.exit(0):process.exit(1)).catch(()=>process.exit(1))" \
    >/dev/null 2>&1
}

# How many log lines a failed start prints, per failing service.
COMPOSE_FAIL_LOG_LINES=40

# The services named in $@ that are not up. One `<service>|<status>` line each;
# no output at all means every one of them is running and, where it declares a
# healthcheck, healthy.
#
# This exists because `up -d --wait` cannot answer the question on its own. It
# waits for a healthcheck, so a service that declares none is "ready" the moment
# its container is running, and a container that is crash-looping is running
# between restarts: `--wait` returned 0 over a Prometheus whose config had a
# typo, and the install reported success and handed the operator a URL that
# answered nothing. Docker's own container state is the honest answer, so ask
# for it after the wait rather than trusting the wait alone.
#
# A service with no container at all is a failure too (an image that would not
# pull leaves nothing behind), which is why this walks the requested names
# rather than listing what the project happens to hold.
#
# Requires: build_compose_cmd has run, so COMPOSE is set.
failed_compose_services() {
  local project svc rows state status
  project="$(compose_project_name)"
  for svc in "$@"; do
    # `oneoff=False` excludes the containers `docker compose run` creates. They
    # carry the same project and service labels, `docker compose ps` does not
    # list them, and one survives whenever a `run --rm` is killed rather than
    # exiting (a dropped SSH session, the OOM killer). install.sh runs its
    # preflight that way, so without this filter the documented recovery,
    # re-running install.sh, aborts a healthy install on the exit status of a
    # dead container from the interrupted run.
    rows="$(docker ps -a \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.service=${svc}" \
      --filter "label=com.docker.compose.oneoff=False" \
      --format '{{.State}}|{{.Status}}' 2>/dev/null || true)"
    if [[ -z "$rows" ]]; then
      printf '%s|%s\n' "$svc" "no container was created"
      continue
    fi
    while IFS='|' read -r state status; do
      [[ -n "$state" ]] || continue
      # `(health: starting)` is not reported: that is a container inside its
      # start_period, which only reaches here when the wait itself failed.
      if [[ "$state" != "running" || "$status" == *"(unhealthy)"* ]]; then
        printf '%s|%s\n' "$svc" "${status:-$state}"
      fi
    done <<< "$rows"
  done
}

# True when every service named in $@ is up. The predicate half of
# report_failed_compose_services, so a caller can put the question in an `if`
# without printing anything.
all_compose_services_up() {
  [[ -z "$(failed_compose_services "$@")" ]]
}

# Report the services from $@ that are not up, then print the last
# COMPOSE_FAIL_LOG_LINES lines of EACH FAILING ONE. Returns 1 when it reported
# something, 0 when everything asked about is up.
#
# Only the failing services' logs, deliberately. Dumping the tail of all five
# put the one line that explained the failure under 160 lines of Grafana
# plugin-install chatter, in a terminal the operator is reading at the moment
# the install broke.
#
# Requires: build_compose_cmd has run, so COMPOSE is set.
report_failed_compose_services() {
  local failures svc status
  failures="$(failed_compose_services "$@")"
  [[ -n "$failures" ]] || return 0

  while IFS='|' read -r svc status; do
    [[ -n "$svc" ]] || continue
    error "  ${svc}: ${status}"
  done <<< "$failures"

  while IFS='|' read -r svc status; do
    [[ -n "$svc" ]] || continue
    echo ""
    error "Last ${COMPOSE_FAIL_LOG_LINES} log lines of ${svc}:"
    "${COMPOSE[@]}" logs --tail "${COMPOSE_FAIL_LOG_LINES}" --no-log-prefix "$svc" 2>&1 | sed 's/^/    /' || true
  done <<< "$failures"

  echo ""
  error "Full logs: docker compose logs <service>"
  return 1
}

# The monitoring services that read their whole configuration once, at process
# start, from a file bind-mounted out of this checkout.
# `<service>:<file under compose/>`.
MOUNTED_CONFIG_SERVICES=(
  "otel-collector:otel-collector-config.yaml"
  "prometheus:prometheus.yml"
)

# Restart those of them that are already running, so the file on disk is the
# file the process is holding.
#
# Compose will not do it. A mounted file's CONTENT is no part of the service
# definition Compose hashes, so `up -d` after the file changed prints `Running`
# and hands back the SAME container id, with the process still on what it read
# when it started. (A top-level `configs:` entry sourced from a file behaves
# identically; both were driven against Compose 2.40.)
#
# That is how the collector's `agledger_` filter would have reached no existing
# install. The collector is the one monitoring service whose definition the
# release carrying that filter does not change, precisely because it is the one
# that can hold no healthcheck: every other monitoring container is recreated by
# the upgrade and it is not, so the operator upgrades, the collector keeps
# re-exporting the millisecond-bucketed copies, and every p95 panel stays where
# it was.
#
# Unconditional, rather than only when the file changed. Asking whether it
# changed needs either the container's start time, which costs a `date -d` these
# scripts may not use (the deploy tests refuse GNU-only flags, because macOS
# ships BSD userland), or a digest recorded somewhere that then has to be kept
# honest across two stacks and a restore. Neither of these two services holds
# anything worth that: Prometheus keeps its series on a volume and the collector
# holds at most one 5s batch, so a restart on an operator-initiated install or
# upgrade costs a few seconds of telemetry and no data.
#
# Grafana is deliberately absent. It re-reads provisioned dashboards from disk
# on its own interval, so the files that change every release are already
# covered, and it is the one of the three holding a database.
#
# Requires: build_compose_cmd has run, so COMPOSE is set.
restart_mounted_config_services() {
  local project entry svc file cid
  project="$(compose_project_name)"
  for entry in "${MOUNTED_CONFIG_SERVICES[@]}"; do
    svc="${entry%%:*}"
    file="${COMPOSE_DIR}/${entry#*:}"
    [[ -f "$file" ]] || continue
    # `|| true` for the same reason the legacy-backup probe carries one: a
    # docker that answers non-zero here would otherwise take the whole install
    # down through `pipefail`, with its message already sent to /dev/null.
    # `oneoff=False` for the same reason failed_compose_services carries it.
    cid="$(docker ps -q \
      --filter "label=com.docker.compose.project=${project}" \
      --filter "label=com.docker.compose.service=${svc}" \
      --filter "label=com.docker.compose.oneoff=False" 2>/dev/null | head -1 || true)"
    # Nothing running under that name: whatever `up -d` creates next reads the
    # file as it stands now, so there is nothing to apply.
    [[ -n "$cid" ]] || continue
    info "Restarting ${svc} so it reads the ${entry#*:} in this checkout."
    "${COMPOSE[@]}" restart "$svc" >/dev/null 2>&1 \
      || warn "  ${svc} did not restart. Apply its configuration with: docker compose restart ${svc}"
  done
}

# True when $1 is a digest ref (`repo@sha256:...`) whose exact bytes this host
# already holds locally.
#
# The point is a registry the host cannot reach. A failed pull is not evidence
# about the image, and on an air-gapped or briefly offline host it is the normal
# case; when the bytes .env already pins are sitting in the local image store,
# a run can go on with them rather than refusing to reconcile anything.
# Deliberately an exact RepoDigest match: a tag that resolves to something local
# is a weaker claim, since a tag can be repointed and nothing verified this one.
#
# Captured and matched with a here-string rather than piped into `grep -q`, for
# the pipefail/EPIPE reason `monitoring_containers_running` above carries: an
# image pulled under several names has a RepoDigests list, and a false "no" here
# turns an offline reconcile into a refusal.
local_image_matches_pin() {
  local pin="$1" digests
  [[ "$pin" == *"@sha256:"* ]] || return 1
  digests="$(docker image inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$pin" 2>/dev/null || true)"
  [[ -n "$digests" ]] || return 1
  grep -qxF "$pin" <<< "$digests"
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
# just rejected.
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

# Set RESOLVED_DIGEST to the digest $ref carries for THIS repo specifically.
# RepoDigests can hold entries for other repos the same image ID was previously
# pulled under (mirror/ECR), so blindly taking [0] could yield a foreign digest.
# Accepts only a well-formed sha256; otherwise leaves it empty so callers skip
# pinning rather than write junk. An image built here or loaded from a tarball
# carries no RepoDigests at all, and empty is the right answer for it: compose
# takes the tag fallback and install.sh writes no pin.
resolve_repo_digest() {
  local image="$1" ref="$2"
  RESOLVED_DIGEST=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$ref" 2>/dev/null \
    | grep "^${image}@" | head -1 | sed 's/.*@//' || true)
  [[ "$RESOLVED_DIGEST" == sha256:* ]] || RESOLVED_DIGEST=""
}

# Pull + cryptographically verify a Docker Hub image BEFORE anything runs it,
# then expose its digest in the global RESOLVED_DIGEST. The image is executed to
# mint the vault signing key, so an unverified/tampered image is silent RCE +
# key exfiltration; this is the gate that closes that.
#
# Policy (OOTB-first: a default install must still boot):
#   AGLEDGER_SKIP_VERIFY=true      -> skip entirely (dev/local ONLY), warn.
#   custom/private --image         -> skip (not signed by our pipeline), warn.
#   cosign present + verify FAILS   -> abort (fail closed). The RCE gate.
#   cosign present + verify OK      -> proceed.
#   cosign absent                  -> warn loudly + proceed, UNLESS
#                                     AGLEDGER_REQUIRE_VERIFY=true (then abort).
#   pull FAILS + image already in the local image store
#                                  -> proceed unverified for the two outcomes
#                                     above that verify nothing either way
#                                     (skip, custom image), warn; abort
#                                     otherwise, and always under
#                                     AGLEDGER_REQUIRE_VERIFY=true.
# Returns non-zero only when the caller should abort. Sets RESOLVED_DIGEST from
# whatever the daemon holds for the ref (verified or not) so callers can still
# digest-pin; an image built here or loaded from a tarball carries no
# RepoDigest, and then the pin is empty and compose runs the tag.
#
# Five of the six outcomes above return 0 and only one of them verified
# anything, so the return code does not answer "was this image verified".
# SIGNATURE_VERIFIED does, and callers that report on the digest have to read
# it: pinning an unverified digest is right, and calling that digest verified
# on the same run that printed "Proceeding UNVERIFIED" hands a log scraper
# looking for evidence of supply-chain verification a false positive.
verify_image() {
  local image="$1" version="$2"
  local ref="${image}:${version}"
  RESOLVED_DIGEST=""
  # shellcheck disable=SC2034  # read by install.sh and upgrade.sh, which source this file
  SIGNATURE_VERIFIED=false
  # shellcheck disable=SC2034  # read by install.sh and upgrade.sh, which source this file
  UNVERIFIED_REASON="not attempted"

  step "Verifying image signature"

  if ! docker pull "$ref"; then
    # A pull failure is only fatal where this run was going to verify something.
    # Where it was not, a copy already in the local image store is the whole of
    # what a successful pull would have produced, and refusing it withholds an
    # install that a reachable registry would have completed just as unverified.
    # restore.sh takes the same position, skipping its own pull for an image
    # `docker image inspect` resolves and naming `docker load` from an air-gap
    # bundle as a way to put one there.
    #
    # So this mirrors the policy below, for the two outcomes that verify nothing
    # either way: AGLEDGER_SKIP_VERIFY, and a custom image the release pipeline
    # never signed. The cosign outcomes are not here, because a keyless check
    # reads the signature from the registry and there is no registry.
    #
    # Without it, an image that exists only locally cannot be installed at all
    # on a first run. install.sh's offline fallback needs a digest pin an earlier
    # install left in .env, so it reaches none of these: an enclave seeded by
    # `docker load` with no internal registry to push to, an internal mirror
    # pulled out of band under its own name, or a customer running an image they
    # built from source.
    # shellcheck disable=SC2034  # read by install.sh, which reports on it
    IMAGE_PRESENT_LOCALLY=false
    if docker image inspect "$ref" >/dev/null 2>&1; then IMAGE_PRESENT_LOCALLY=true; fi

    # AGLEDGER_REQUIRE_VERIFY is decisive here and nowhere else in this function.
    # On a reachable registry it only governs a missing cosign, because the other
    # skip outcomes were the operator's own choice. A failed pull is not: the
    # operator asked for a refusal on bytes this run did not verify, and these
    # are exactly those bytes. install.sh's own copy of this check says the same.
    if [[ "$IMAGE_PRESENT_LOCALLY" == "true" && "${AGLEDGER_REQUIRE_VERIFY:-false}" != "true" ]]; then
      local local_reason=""
      if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
        local_reason="AGLEDGER_SKIP_VERIFY=true"
      elif [[ "$image" != "agledger/agledger" ]]; then
        local_reason="custom image, not signed by the AGLedger release pipeline"
      fi
      if [[ -n "$local_reason" ]]; then
        # shellcheck disable=SC2034  # read by install.sh and upgrade.sh
        UNVERIFIED_REASON="${local_reason}; pull failed, used the local image store's copy"
        warn "docker pull ${ref} failed, but ${local_reason}, and that image is already in this"
        warn "host's local image store. Continuing on those bytes."
        warn "NOTHING WAS VERIFIED, and nothing compared them against a registry: they are whatever"
        warn "put them there."
        resolve_repo_digest "$image" "$ref"
        return 0
      fi
    fi

    if [[ "$IMAGE_PRESENT_LOCALLY" == "true" ]]; then
      # Present locally and still refused: a keyless check reads the signature
      # from the registry, so an unreachable registry makes these bytes
      # unverifiable, not absent. Reporting "isn't present" here sends an
      # operator looking for an image `docker image inspect` resolves in front
      # of them.
      error "docker pull ${ref} failed. That image IS in this host's local image store, but a"
      error "keyless signature check reads the signature from the registry, so this run cannot"
      error "verify those bytes."
      if [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
        error "AGLEDGER_REQUIRE_VERIFY=true, which is a refusal to run bytes this run did not verify."
      else
        error "For dev/local ONLY, install from them unverified with: --skip-verify"
      fi
    else
      error "docker pull ${ref} failed — cannot verify or run an image that isn't present."
    fi
    local pull_registry="${image%%/*}"
    if [[ "$image" == */* && ( "$pull_registry" == *.* || "$pull_registry" == *:* ) ]]; then
      if [[ "$IMAGE_PRESENT_LOCALLY" != "true" ]]; then
        error "Nothing is wrong with the signature: the image never arrived."
      fi
      error "'${pull_registry}' is a private registry, and the daemon has no credentials for it"
      error "if the output above says 'no basic auth credentials'. Authenticate, then re-run:"
      if [[ "$pull_registry" == *.dkr.ecr.*.amazonaws.com ]]; then
        local pull_region="${pull_registry#*.dkr.ecr.}"
        pull_region="${pull_region%%.amazonaws.com}"
        error "  aws ecr get-login-password --region ${pull_region} | docker login --username AWS --password-stdin ${pull_registry}"
      else
        error "  docker login ${pull_registry}"
      fi
    fi
    # 2, not 1: the caller reports a signature failure on 1, and this is not
    # one. An image that never downloaded was never verified either way.
    return 2
  fi
  resolve_repo_digest "$image" "$ref"

  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    UNVERIFIED_REASON="AGLEDGER_SKIP_VERIFY=true"
    warn "AGLEDGER_SKIP_VERIFY=true — skipping image signature verification (dev/local ONLY, never production)."
    return 0
  fi
  if [[ "$image" != "agledger/agledger" ]]; then
    UNVERIFIED_REASON="custom image, not signed by the AGLedger release pipeline"
    warn "Custom image '${image}' is not signed by the AGLedger release pipeline — skipping signature verification."
    return 0
  fi
  if ! command -v cosign &>/dev/null; then
    # shellcheck disable=SC2034  # read by install.sh and upgrade.sh
    UNVERIFIED_REASON="cosign not installed"
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
    # shellcheck disable=SC2034  # read by install.sh and upgrade.sh
    SIGNATURE_VERIFIED=true
    info "Image signature verified (keyless, public Rekor): ${image}@${RESOLVED_DIGEST}"
    return 0
  fi

  error "Image signature verification FAILED for ${image}@${RESOLVED_DIGEST}."
  error "This is NOT a genuine AGLedger release (tampered, swapped, or unsigned image)."
  error "Refusing to run it. Override for local/dev ONLY with: AGLEDGER_SKIP_VERIFY=true"
  return 1
}

# Verify a signed Helm OCI chart's keyless signature.
# Same policy as verify_image. The chart ref is the OCI image form
# (registry-1.docker.io/agledger/agledger-chart:<version>).
verify_chart() {
  local chart_ref="$1"   # e.g. registry-1.docker.io/agledger/agledger-chart:1.0.3

  # Reset the same pair verify_image sets. A caller that verified an image and
  # then a chart would otherwise report the chart under the image's verdict,
  # which is the false-verified claim this pair exists to prevent.
  # shellcheck disable=SC2034  # read by scripts that source this file
  SIGNATURE_VERIFIED=false
  # shellcheck disable=SC2034  # read by scripts that source this file
  UNVERIFIED_REASON="not attempted"

  step "Verifying Helm chart signature"

  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    # shellcheck disable=SC2034  # read by scripts that source this file
    UNVERIFIED_REASON="AGLEDGER_SKIP_VERIFY=true"
    warn "AGLEDGER_SKIP_VERIFY=true — skipping chart signature verification (dev/local ONLY)."
    return 0
  fi
  if ! command -v cosign &>/dev/null; then
    if [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
      error "cosign not installed and AGLEDGER_REQUIRE_VERIFY=true. Install cosign 3.x."
      return 1
    fi
    # shellcheck disable=SC2034  # read by scripts that source this file
    UNVERIFIED_REASON="cosign not installed"
    warn "cosign not installed — cannot verify the chart signature before install."
    warn "Install cosign 3.x: https://docs.sigstore.dev/system_config/installation/"
    warn "Proceeding UNVERIFIED. Set AGLEDGER_REQUIRE_VERIFY=true to make this fatal."
    return 0
  fi

  if cosign verify \
       --certificate-identity-regexp "$AGLEDGER_SIGNER_IDENTITY_REGEXP" \
       --certificate-oidc-issuer "$AGLEDGER_SIGNER_OIDC_ISSUER" \
       "$chart_ref" >/dev/null 2>&1; then
    # shellcheck disable=SC2034  # read by scripts that source this file
    SIGNATURE_VERIFIED=true
    info "Chart signature verified (keyless, public Rekor): ${chart_ref}"
    return 0
  fi

  error "Chart signature verification FAILED for ${chart_ref}."
  error "Refusing to install an unverified chart. Override for dev ONLY with: AGLEDGER_SKIP_VERIFY=true"
  return 1
}

# --- ECR Authentication ---

# Authenticate the docker daemon against the registry the install is pulling
# from.
#
# The registry is the host part of the image reference, so `--image` already
# names it and an operator should not have to know a second variable to make
# that flag work. ECR_REGISTRY stays as an override for the case where the two
# genuinely differ (a pull-through cache, an air-gap mirror).
#
# Only ECR hosts can be logged into unattended, because only ECR mints a
# password from an existing AWS identity. Any other private registry needs a
# `docker login` the operator performs; say so rather than warning about a
# variable that would not have helped.
registry_host_from_image() {
  local first="${1%%/*}"
  [[ "$1" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == "localhost" ) ]] || return 1
  echo "$first"
}

ecr_login() {
  local registry="$ECR_REGISTRY"
  if [[ -z "$registry" ]]; then
    registry="$(registry_host_from_image "$AGLEDGER_IMAGE" || true)"
    [[ -n "$registry" ]] && info "Registry read from the image reference: ${registry} (override with ECR_REGISTRY)"
  fi

  if [[ -z "$registry" ]]; then
    info "Image '${AGLEDGER_IMAGE}' names no registry host, so it resolves on Docker Hub. No login attempted."
    return
  fi

  if [[ "$registry" != *.dkr.ecr.*.amazonaws.com ]]; then
    info "'${registry}' is not an ECR host, so there is no unattended login for it."
    info "If the pull below fails with 'no basic auth credentials', run: docker login ${registry}"
    return
  fi

  if ! command -v aws &>/dev/null; then
    warn "AWS CLI not found, so ECR login was skipped. Either install it, or run this first:"
    warn "  aws ecr get-login-password --region <region> | docker login --username AWS --password-stdin ${registry}"
    return
  fi

  # The region is in the host (<account>.dkr.ecr.<region>.amazonaws.com), so
  # read it there rather than defaulting to one and failing in another.
  local region="${registry#*.dkr.ecr.}"
  region="${region%%.amazonaws.com}"
  [[ -n "$region" ]] || region="${AWS_REGION:-us-west-2}"

  if aws ecr get-login-password --region "$region" 2>/dev/null | docker login --username AWS --password-stdin "$registry" 2>/dev/null; then
    info "Authenticated with ECR (${registry}, region ${region})"
  else
    warn "ECR login failed for ${registry} in ${region}. If using an air-gap bundle, this is expected."
    warn "Otherwise check the caller identity: aws sts get-caller-identity"
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
  # This queries the public agledger/agledger Docker Hub repository
  # unconditionally, so it must not be asked to resolve "latest" for any other
  # registry: a private registry's tag list is not Docker Hub's, and a
  # semver it happens to publish under that number may not exist there at
  # all. AGLEDGER_IMAGE is resolved by the time any caller reaches this,
  # whether from an explicit --image or from a persisted one in .env
  # (install.sh applies both before version resolution, precisely so this
  # sees the real registry either way), so read it directly rather than
  # taking a parameter every caller has to remember to pass.
  if [[ "${AGLEDGER_IMAGE:-agledger/agledger}" != "agledger/agledger" ]]; then
    echo "ERROR: no --version given, and the image is ${AGLEDGER_IMAGE}, not Docker Hub's agledger/agledger. Its tag list is not Docker Hub's, so a version cannot be resolved from there. Pass --version <tag>." >&2
    return 1
  fi
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
      # returning it: a published-then-deleted tag (rare but real: v0.21.1
      # was pulled after release) leaves the cache pointing at a 404. Cheap
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
    # also see the warning, which is the point.
    echo "WARN: Docker Hub unreachable; using cached latest-version (age: ~${age_min} min). Pin with --version X.Y.Z to be explicit, or check network and retry." >&2
    cat "$cache_file"
    return 0
  fi

  return 1
}

# What the AGLEDGER_IMAGE line in .env should become, given the registry this
# run resolved and the one the file already names. Prints `set`, `delete` or
# `keep`.
#
# A function rather than an inline `if` so it can be driven directly: two of the
# three outcomes are silent no-ops from outside, and the third writes .env, so a
# wrong branch shows up only as a registry that did not move or containers that
# recreate on every run.
image_line_action() {
  local resolved="$1" existing="$2"
  if [[ "$resolved" != "agledger/agledger" ]]; then
    # A private registry has to be recorded, or upgrade.sh falls back to Docker
    # Hub and pulls the next version from the wrong place.
    [[ "$existing" == "$resolved" ]] && { echo keep; return 0; }
    echo set; return 0
  fi
  # This run wants Docker Hub. A line naming another registry has to go, or the
  # next upgrade authenticates to a registry this install has left. A line
  # spelling out `agledger/agledger` names the same thing this run wants: it is
  # redundant, not wrong, and deleting it recorded a Docker-Hub-to-Docker-Hub
  # change on every run, which recreated every container for a no-op re-install.
  if [[ -n "$existing" ]] && [[ "$existing" != "agledger/agledger" ]]; then
    echo delete; return 0
  fi
  echo keep
}

# Delete every line that SETS key from an env file.
#
# The pattern has to match the same shapes `get_env_value` reads, or the two
# disagree and the caller reports a change it did not make: a `.env` carrying
# `export AGLEDGER_IMAGE=...` reads as set, survives a `/^AGLEDGER_IMAGE=/d`
# delete untouched, and the operator is told the install moved registries while
# `upgrade.sh` still authenticates to the old one.
delete_env_var() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sedi -E "/^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=/d" "$file"
}

# --- Values this run resolved, held across a `source .env` ---
#
# Sourcing .env puts the persisted value of every variable it names back into
# the shell, on top of whatever this run already resolved. For anything whose
# precedence chain is flag > .env > default, that inverts the order: the flag
# has already been applied and .env then overwrites it.
#
# It is not only the running value that is lost. install.sh reconciles .env by
# comparing the resolved value against what the file holds, so a clobbered
# variable compares equal to itself, nothing is written, and the run reports
# success having changed nothing.
#
# Two parallel indexed arrays rather than one associative array: macOS ships
# bash 3.2, which has none. `${!name-}` is scalar indirect expansion, which
# 3.2 does have.
RESOLVED_VAR_NAMES=()
RESOLVED_VAR_VALUES=()

snapshot_resolved_var() {
  local name="$1"
  RESOLVED_VAR_NAMES+=("$name")
  RESOLVED_VAR_VALUES+=("${!name-}")
}

restore_resolved_vars() {
  local i
  [[ ${#RESOLVED_VAR_NAMES[@]} -eq 0 ]] && return 0
  for i in "${!RESOLVED_VAR_NAMES[@]}"; do
    printf -v "${RESOLVED_VAR_NAMES[$i]}" '%s' "${RESOLVED_VAR_VALUES[$i]}"
  done
}

# Read FILE's assignments into this shell, decoded the way compose decodes them.
#
# Deliberately not `source`. The shell is a fourth parser with rules of its own,
# and on the one value that matters most it disagreed with every other reader:
# `DATABASE_URL=...?sslmode=require&uselibpqcompat=true` unquoted is two
# commands to the shell, the first backgrounded at the `&`, so DATABASE_URL came
# back UNSET from a file that plainly sets it. Everything downstream then read
# the empty value as "bundled" and operated on the wrong database.
#
# Not sourcing also means an `.env` cannot run commands in the installer's
# shell, which it could before by any of the usual `$(...)` routes.
load_env_file() {
  local file="$1" line key
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]] || continue
    key="${BASH_REMATCH[2]}"
    printf -v "$key" '%s' "$(dotenv_decode_value "${line#*=}")"
    # `export KEY=v` is a spelling operators reach for, and `source` honoured
    # it. Compose passes the variable to containers either way; this keeps the
    # host shell's behaviour the same as before, so a child process that used
    # to inherit the value still does.
    if [[ -n "${BASH_REMATCH[1]}" ]]; then export "${key?}"; fi
  done < "$file"
}

# Read the install's .env if present. Sets POSTGRES_USER, POSTGRES_DB,
# DATABASE_URL, etc.
load_env() {
  load_env_file "${COMPOSE_DIR}/.env"
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
  local url="${DATABASE_URL:-}"
  if [[ -z "$url" ]]; then
    url="$(get_env_value DATABASE_URL "${COMPOSE_DIR}/.env")"
    # The file declares a database and no reader here could make a value out of
    # it. The empty-is-bundled default below would then point backup.sh and
    # restore.sh at the bundled container while the install serves an external
    # one: a backup that reports success, exit 0, over a database holding
    # nothing, and a restore that skips the whole external-path apparatus (the
    # pre-drop privilege gate, the runtime-role check, the pgboss ownership
    # repair) because all of it sits behind `USES_BUNDLED_PG == false`.
    # An install that cannot determine its own database mode has no safe
    # default, so this refuses rather than guesses.
    if [[ -z "$url" ]] && env_file_declares_database_url "${COMPOSE_DIR}/.env"; then
      fatal "DATABASE_URL is set in ${COMPOSE_DIR}/.env but could not be read. Refusing to guess the database mode: every operator script would target the bundled container instead. Check the line for a stray quote or a line break."
    fi
  fi
  if database_url_is_bundled "$url"; then
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

# The operator's own override file, if they wrote one.
#
# Compose applies an override file automatically ONLY when it is discovering the
# compose file itself. Setting COMPOSE_FILE in .env, and passing an explicit
# `-f` list from these scripts, both turn that discovery off, so an override
# file sat beside the stack doing nothing and nothing said so. The compose
# file's own comments tell operators to write one (a worker port mapping), and
# `.env.example` tells them to write one for the SIEM file sink's write grant.
#
# All FOUR names Compose discovers, in ITS precedence order, verified against
# Compose 2.40: with several present it takes the first of
# compose.override.yml, compose.override.yaml, docker-compose.override.yml,
# docker-compose.override.yaml and warns about the rest. Checking only the
# docker-compose pair would silently ignore a file named the way Compose's own
# current documentation names it.
#
# Echoes the basename, or nothing.
compose_override_file() {
  local name
  for name in compose.override.yml compose.override.yaml \
              docker-compose.override.yml docker-compose.override.yaml; do
    if [[ -f "${COMPOSE_DIR}/${name}" ]]; then
      echo "$name"
      return 0
    fi
  done
}

# Build the colon-separated overlay list for the COMPOSE_FILE .env line, in
# the same order and under the same conditions build_compose_cmd applies its
# -f flags, so a manual `docker compose` from compose/ and the scripts agree.
# Sets OVERLAY_LIST. install.sh and upgrade.sh both call this; per-script
# copies drifted (the rebuild path dropped the FIPS overlay, so a --fips
# install whose COMPOSE_FILE line was removed by hand got it rebuilt without
# the overlay while .env still said AGLEDGER_FIPS=true).
build_overlay_list() {
  OVERLAY_LIST="docker-compose.yml"
  if [[ "${USES_BUNDLED_PG}" == "true" ]] && [[ -f "${COMPOSE_DIR}/docker-compose.postgres.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.postgres.yml"
  fi
  if [[ -f "${COMPOSE_DIR}/docker-compose.prod.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.prod.yml"
  fi
  # Last of the shipped overlays, so its OPENSSL_CONF wins over anything an
  # earlier one sets.
  if fips_overlay_enabled && [[ -f "${COMPOSE_DIR}/docker-compose.fips.yml" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:docker-compose.fips.yml"
  fi
  # After every shipped overlay, which is where Compose applies an override file
  # when it discovers one itself. An operator editing this file is editing it to
  # win.
  local override
  override="$(compose_override_file)"
  if [[ -n "$override" ]]; then
    OVERLAY_LIST="${OVERLAY_LIST}:${override}"
  fi
}

# The Compose floor this stack's own compose file needs.
#
# docker-compose.yml declares a top-level `configs:` entry with inline
# `content:`, which is how the bundled Prometheus is handed the /metrics bearer
# token out of .env without a second copy of that secret on disk. Compose gained
# inline content in 2.23.1. Older Compose does not ignore the key, it fails to
# parse the file, so this bites `down`, `logs` and `ps` as hard as `up`.
#
# Echoes "ok" or a human reason. The caller decides whether that is fatal, so
# `install.sh` can refuse up front while a day-2 script can warn.
COMPOSE_MIN_VERSION="2.23.1"

compose_version_state() {
  local raw major minor patch
  raw="$(docker compose version --short 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    echo "Docker Compose v2 is not installed."
    return 0
  fi
  # Strip a leading v and any suffix a distribution appends
  # (2.40.3+ds1-0ubuntu1~24.04.1, 2.24.0-desktop.1).
  raw="${raw#v}"
  major="${raw%%.*}"; raw="${raw#*.}"
  minor="${raw%%.*}"; raw="${raw#*.}"
  patch="${raw%%[!0-9]*}"
  # A component that is not a number would make the arithmetic below evaluate a
  # variable name under `set -u`. Refuse to guess instead.
  if [[ ! "$major$minor" =~ ^[0-9]+$ ]]; then
    echo "Could not read a version number from \`docker compose version --short\`."
    return 0
  fi
  [[ "$patch" =~ ^[0-9]+$ ]] || patch=0
  if (( major > 2 )) \
     || (( major == 2 && minor > 23 )) \
     || (( major == 2 && minor == 23 && patch >= 1 )); then
    echo "ok"
  else
    echo "Docker Compose ${COMPOSE_MIN_VERSION}+ is required (found ${major}.${minor}.${patch})."
  fi
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

  # Last of the shipped overlays, so its OPENSSL_CONF wins over anything an
  # earlier one sets.
  if fips_overlay_enabled && [[ -f "${fips_file}" ]]; then
    COMPOSE+=(-f "${fips_file}")
  fi

  # The operator's override file, after everything shipped. This list and the
  # COMPOSE_FILE line build_overlay_list writes have to name the same files in
  # the same order, or a manual `docker compose` and these scripts deploy
  # different stacks.
  local override
  override="$(compose_override_file)"
  if [[ -n "$override" ]]; then
    COMPOSE+=(-f "${COMPOSE_DIR}/${override}")
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
