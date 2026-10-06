#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Restore Script
# =============================================================================
# Restores PostgreSQL data from a backup tarball.
# Works with both bundled PostgreSQL and external databases (Aurora, RDS, etc.).
#
# Usage: ./scripts/restore.sh [options] <backup-tarball>
#        ./scripts/restore.sh backup/backup-agledger-2026-03-14-120000.tar.gz
#
# Options:
#   --non-interactive          Take the restore without the confirmation prompt.
#   --force                    Drop a database that holds tables which are not
#                              this install's. Refused without it.
#   --keep-version             Stay on the installed release instead of
#                              returning to the one the backup was taken from.
#   --target bundled|external  Which database this run drops, when a
#                              DATABASE_URL naming localhost could be either.
#   --no-start                 Leave the compose stack down at the end.
#   --version <X.Y.Z>          The release this install runs, for a host whose
#                              compose/.env names none (restoring into a
#                              cluster). AGLEDGER_VERSION in the environment
#                              does the same. Refused when compose/.env names
#                              a different one.
#   -h, --help                 Print this and exit.
#
# A backup carries the version it was taken from. When that is not the version
# installed now, the restore returns the install to it, because the dump and the
# schema have to agree: starting the newer release over an older dump re-applies
# that release's migrations on top of it. --keep-version stays on the installed
# release instead and says what that means.
#
# The migration, the privilege check and the post-restore steps run in the image
# of the release this install runs, so the run refuses before anything is
# stopped when nothing names that release. It never falls back to `latest`.
#
# On an external database with a separate runtime role (the chart's bundled
# PostgreSQL is one), pass DATABASE_URL as the runtime role and
# DATABASE_URL_MIGRATE as the owner, the way the Server takes them. Given one
# URL, the restore treats that role as both, and refuses when the database it
# is about to replace says the install serves as another.
#
# A host with no compose/.env is restoring into a Kubernetes release, and the
# steps after the migration (re-applying revocations made after the backup,
# the restore marker, the external-anchor comparison) need that release's own
# configuration, which this host does not hold. The run writes their input to
# a directory under the backup root and ends by printing the kubectl commands
# that run them as the chart's post-restore Job.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false
FORCE=false
KEEP_VERSION=false

# When this run started, and the name it records itself under. Both are fixed
# here rather than at the point they are used, so a run that takes twenty
# minutes still records the moment the operator asked for the restore, and a run
# re-tried after an interruption records a different one.
RESTORE_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
# The restore's own identifier, unique in the restored database. The pid is in
# it because the timestamp has one-second resolution, and `marker_id` is UNIQUE:
# two runs that started in the same second would otherwise be one marker and one
# chain entry between them. Fixed here so the message that tells an operator how
# to re-run the post-restore step by hand names the same id the run would use.
RESTORE_MARKER_SUFFIX="${RESTORE_STARTED_AT}-$$"
# What the post-restore step reports, read by the closing notes: ok, rewound,
# failed, or skipped.
POST_RESTORE_OUTCOME=skipped
# What the migration run in the post-restore step ended as: ok, failed (it
# exited non-zero), refused (exit 65, another release line's database), or
# pending (it has not run).
MIGRATE_OUTCOME=pending

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

# The revocations read out of the database about to be replaced, copied out of
# the run's temp directory before the drop (empty when there were none to keep,
# or on a cluster, whose post-restore input directory holds them), whether the
# closing notes have named it, and whether this run has started dropping.
REVOCATIONS_SAVED=""
REVOCATION_NOTES_PRINTED=false
DATABASE_DROPPED=false

# Where the saved revocations are and how to replay them. $1 is the marker id
# the replay runs under: this run's, when the operator finishes this run by
# hand, or a placeholder for the one a re-run reports.
revocations_saved_note() {
  local marker="$1"
  log "  They are saved at ${REVOCATIONS_SAVED}, the only copy once the database they were read out of"
  log "  is dropped. A re-run of this script does not read them again: it reads revocations out of the"
  log "  database it replaces, which after the drop does not hold them. Once a restore of this archive"
  log "  has completed and the schema is current, replay them:"
  log "    ${COMPOSE[*]} run --rm --no-deps -T -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api \\"
  log "      dist/scripts/post-restore.js --marker-id ${marker} --replay-revocations - < ${REVOCATIONS_SAVED}"
  if [[ "${marker}" == "<marker id>" ]]; then
    log "  The marker id is the re-run's own, from its 'Restore marker <id> recorded' line."
  else
    log "  That is this run's marker id. If a re-run of this script completes the restore instead, use the"
    log "  one the re-run reports on its 'Restore marker <id> recorded' line."
  fi
  log "  A marker already written is left as it is, so the replay adds no second one."
}

# A refusal before this run has stopped or dropped anything. $1 is what to do
# next; with no argument, the install is said to be serving as it was.
#
# That is true on Compose, where this run is what stops the stack. On a cluster
# the Kubernetes runbook scales the api and worker Deployments to 0 before it
# runs this script, so nothing is serving, and the way out is a re-run or the
# scale back up, which the refusal names.
refuse_untouched() {
  local next
  if [[ $# -eq 0 ]]; then next="Your install is serving exactly as it was."; else next="$1"; fi
  if [[ "${CLUSTER_RESTORE:-false}" == true ]]; then
    log "This run stopped nothing and dropped nothing. If you scaled the api and worker Deployments to"
    log "  0 for this restore, as the Kubernetes runbook does before restore.sh, they are still at 0"
    log "  and the release is serving nothing. Re-run once the cause above is fixed, or put each back"
    log "  to the count you recorded:"
    log "    kubectl scale -n \"\$NS\" --replicas=<recorded count> deploy/<name>"
    [[ $# -eq 0 ]] && next=""
    die "Nothing was stopped and nothing was dropped by this run.${next:+ ${next}}"
  fi
  die "Nothing was stopped and nothing was dropped.${next:+ ${next}}"
}

# The header block above, with the comment markers taken off: one place to read
# and one place to edit. It runs to the rule that closes the block rather than
# to a line number, so a paragraph added to the header cannot push the options
# out of what --help prints.
usage() {
  awk '/^# ={10,}/ { rules++ }
       NR >= 4     { sub(/^# ?/, ""); print }
       rules == 3  { exit }' "${BASH_SOURCE[0]}"
}

# The release this run's containers run: the revocation read, the privilege
# check, the migration and the post-restore steps are each a `docker compose run`
# of the image AGLEDGER_VERSION names, and the compose files fall back to
# `latest` when nothing names one. `latest` is whatever was published last, not
# the release this install runs, and another release's migration either refuses
# the restored dump or moves its schema ahead of the Server about to serve it.
# So there is no fallback here.
#
# $1 --version, $2 AGLEDGER_VERSION in compose/.env, $3 AGLEDGER_VERSION in the
# calling environment. compose/.env is the install's own record and wins over
# the environment, as it does for every value load_env reads. A --version that
# disagrees with it is refused: moving a Compose install is install.sh's job.
#
# Prints one of:
#   ok <version>        the release to run
#   conflict <version>  --version disagrees with the release compose/.env names
#   none [<value>]      nothing names a release; <value> is what was named instead
restore_serving_version() {
  local flag="${1#v}" file="$2" env="$3" chosen
  # A compose/.env naming something that is not a release (`latest`, a
  # testbed tag) is not a record of one, so a concrete --version overrides it
  # rather than conflicting with it; otherwise the refusal below would send the
  # operator to --version and --version back to the refusal.
  if [[ -n "${flag}" && -n "${file}" ]] && is_concrete_version "${file}"; then
    if [[ "${file#v}" != "${flag}" ]]; then
      printf 'conflict %s\n' "${file}"
      return 0
    fi
  elif [[ -n "${flag}" ]]; then
    file=""
  fi
  chosen="${file:-${flag:-${env}}}"
  if is_concrete_version "${chosen}"; then
    printf 'ok %s\n' "${chosen}"
  else
    printf 'none %s\n' "${chosen}"
  fi
}

# Whether one URL is enough for this database. $1 is whether DATABASE_URL_MIGRATE
# was given, $2 the role the restore connects as, $3 the owner of the pgboss
# schema in the database about to be replaced (empty when there is none).
#
# pg-boss installs its schema as the role the Server connects as, so its owner is
# the install's runtime role. Given one URL, the restore takes that URL's role for
# the runtime role as well: it hands pgboss and the database grants to it, and a
# Server that connects as a different role then stops at boot on `permission
# denied for schema pgboss`. The chart's bundled PostgreSQL is that install: the
# api connects as agledger_app, the migration as agledger.
#
# Prints `ok`, or `split` when the database says the install serves as a role
# other than the one this run was given.
restore_role_verdict() {
  local migrate_given="$1" restoring_role="$2" pgboss_owner="$3"
  if [[ "${migrate_given}" != true && -n "${pgboss_owner}" && "${pgboss_owner}" != "${restoring_role}" ]]; then
    echo split
  else
    echo ok
  fi
}

# The directory the chart's post-restore Job reads, as a Secret, on a cluster
# restore: one file per value, named as `post-restore.js --restore-input`
# reads them. $1 is the directory. The revocations go in only when this run
# exported them; with none, the Job replays none and the closing notes say what
# to compare instead.
write_post_restore_input() {
  local dir="$1"
  ( umask 077 && mkdir -p "${dir}" ) || return 1
  printf '%s\n' "kubernetes-${RESTORE_MARKER_SUFFIX}" > "${dir}/marker-id" || return 1
  printf '%s\n' "${RESTORE_STARTED_AT}" > "${dir}/restored-at" || return 1
  printf '%s\n' "$(basename "${TARBALL}")" > "${dir}/archive" || return 1
  if [[ "${REVOCATION_OUTCOME}" == exported ]]; then
    gzip -c "${REVOCATIONS_FILE}" > "${dir}/revocations.ndjson.gz" || return 1
  fi
  chmod 600 "${dir}"/* || return 1
}

# Parse arguments
TARBALL=""
# Which database this run drops: bundled or external. Empty means classify the
# URL, which detect_db_mode refuses for a DATABASE_URL handed in from the
# environment that names localhost, since a port-forwarded cluster database and
# the bundled container look the same from here.
DB_TARGET=""
# Leave the compose stack down at the end. The cluster recipe passes this: the
# workloads it restores for are the cluster's Deployments, not containers here.
NO_START=false
# The release named on the command line, and the one the calling environment
# names, read before load_env can overwrite the variable from compose/.env.
VERSION_FLAG=""
ENV_AGLEDGER_VERSION="${AGLEDGER_VERSION:-}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --force) FORCE=true; shift ;;
    --keep-version) KEEP_VERSION=true; shift ;;
    --no-start) NO_START=true; shift ;;
    --version)
      [[ -n "${2:-}" ]] || die "--version needs a value: the release this install runs, e.g. 2.0.0"
      VERSION_FLAG="$2"; shift 2 ;;
    --version=*) VERSION_FLAG="${1#--version=}"; shift ;;
    --target)
      [[ -n "${2:-}" ]] || die "--target needs a value: bundled or external"
      DB_TARGET="$2"; shift 2 ;;
    --target=*) DB_TARGET="${1#--target=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "Unknown option: $1" ;;
    *) TARBALL="$1"; shift ;;
  esac
done
case "${DB_TARGET}" in ''|bundled|external) ;; *) die "--target must be bundled or external, not '${DB_TARGET}'" ;; esac

[[ -n "${TARBALL}" ]] || { usage >&2; die "No backup tarball given."; }
[[ -f "${TARBALL}" ]] || die "Backup file not found: ${TARBALL}"

# A host with no compose/.env is restoring into a cluster: nothing here holds
# the release's signing key, API key secret, external URL or anchor settings,
# and the steps after the migration need all of them. Read before load_env,
# which reads the file and never creates it.
CLUSTER_RESTORE=false
[[ -f "${COMPOSE_DIR}/.env" ]] || CLUSTER_RESTORE=true

# Compose names a checkout's project after its directory, `compose` in every
# checkout of the install repo, and that is also the project of a default
# Compose install on the same host. A cluster restore owns no containers here,
# only the one-off ones it runs, so it runs them under a project of its own and
# never stops, removes or joins another install's.
if [[ "${CLUSTER_RESTORE}" == true ]]; then
  export COMPOSE_PROJECT_NAME=agledger-cluster-restore
fi

load_env
# This run drops the database it classifies, so a DATABASE_URL handed in from the
# environment that names localhost is refused without --target: see
# resolve_db_target in lib-compose.sh.
# shellcheck disable=SC2034  # read by detect_db_mode in lib-compose.sh
DB_TARGET_REQUIRED=true
detect_db_mode

# --- Which release this run's containers run ---
#
# Asked first, above the confirmation prompt: see restore_serving_version.
read -r SERVING_STATE SERVING_ARG <<< "$(restore_serving_version \
  "${VERSION_FLAG}" "$(get_env_value AGLEDGER_VERSION "${COMPOSE_DIR}/.env")" "${ENV_AGLEDGER_VERSION}")"
case "${SERVING_STATE}" in
  ok)
    INSTALLED_VERSION="${SERVING_ARG}"
    # Compose reads the environment before .env, so every `docker compose run`
    # below runs this release's image and none of them can reach `latest`.
    export AGLEDGER_VERSION="${INSTALLED_VERSION}"
    ;;
  conflict)
    log "compose/.env records this install as ${SERVING_ARG}, and --version names ${VERSION_FLAG}."
    log "  The restore runs on the release the install runs. To move a Compose install to another"
    log "  release, use ./scripts/install.sh --version <X.Y.Z>; to restore onto ${SERVING_ARG}, drop --version."
    refuse_untouched
    ;;
  *)
    if [[ -n "${SERVING_ARG:-}" ]]; then
      log "The release named for this restore is '${SERVING_ARG}', which is not a release number, so this"
      log "  restore has no image to run its migration in."
    else
      log "No release is named for this restore, so it has no image to run its migration in:"
      log "  ${COMPOSE_DIR}/.env names no AGLEDGER_VERSION (a host restoring into a cluster has none),"
      log "  and neither the command line nor the environment does."
    fi
    log "  The compose files would fall back to Docker Hub's 'latest', which is whatever was published"
    log "  last and not necessarily the release this install runs. Another release's migration either"
    log "  refuses the restored database or moves its schema ahead of the Server that serves it."
    log ""
    log "  Name the release this install runs and re-run with it:"
    log "    $0 --version <X.Y.Z> ..."
    log "  On Kubernetes that is the Helm release's app version:"
    log "    helm list -n <namespace> -f '^<release>\$' -o json | jq -r '.[0].app_version'"
    refuse_untouched
    ;;
esac

# A cluster restore ends with the compose stack down: the workloads that serve
# the restored database are the cluster's, and they start only after the
# post-restore Job. Without --no-start the run's last step would start a local
# Server on the cluster's database, with none of the release's configuration
# and ahead of that Job.
if [[ "${CLUSTER_RESTORE}" == true && "${NO_START}" != true ]]; then
  log "${COMPOSE_DIR}/.env does not exist, so this is a restore into a cluster, and it ends by starting"
  log "  the compose stack unless told not to: a local Server on the cluster's database, without the"
  log "  release's configuration and before the post-restore steps. Re-run with --no-start."
  refuse_untouched
fi

# The same .env repairs upgrade.sh performs, for the same reason and from the
# other direction. A restore is the DR path: it commonly runs onto a rebuilt
# host out of a checkout whose .env lacks them, and it ends by
# starting the whole stack. Without this the restore brings up a Server with no
# federation identity, no metrics scrape token, an unselected monitoring profile
# and manual `docker compose` commands that drop the overlays, and reports a
# clean restore. Above build_compose_cmd, because the COMPOSE_FILE repair is one
# of them.
reconcile_env_file "${COMPOSE_DIR}/.env"
if [[ "$ENV_RECONCILED" == true ]]; then
  log "Repaired ${COMPOSE_DIR}/.env (the lines above say what). Each repair only fills in a value"
  log "that was absent, so it stands whether or not this restore goes ahead; the containers pick"
  log "the repairs up when this run starts them."
fi

build_compose_cmd

# A host with no compose/.env leaves unset every variable the compose files
# interpolate without a default (API_KEY_SECRET, VAULT_SIGNING_KEY,
# GRAFANA_ADMIN_PASSWORD), and each `docker compose run` below warns about each
# one. Compose substitutes an empty string for them either way, and none of them
# is what the one-off containers here need: those take the database URL from
# this environment, and the rest is the release's. Exported empty, the
# substitution is the same and the warnings are gone. Read from the compose
# files, so a variable added there is covered without a list to keep.
if [[ "${CLUSTER_RESTORE}" == true ]]; then
  while IFS= read -r compose_var; do
    [[ -n "${compose_var}" && -z "${!compose_var+set}" ]] && export "${compose_var}="
  done < <(cat "${COMPOSE_DIR}"/docker-compose*.yml 2>/dev/null \
             | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | sed -E 's/^\$\{(.*)\}$/\1/' | sort -u)
fi

# --- Which database ---
#
# On the external path this is the database DATABASE_URL names, not POSTGRES_DB.
# POSTGRES_DB configures the bundled PostgreSQL container. It is in every
# install's .env at its `agledger` default, because install.sh copies
# .env.example whole, and only the bundled path ever re-records it — so on an
# external install it is a stale default that names nothing. Reading it here
# sent the restore to the right server and the wrong database: a new empty
# `agledger` was created and restored into while the real database was left
# untouched, and the DROP that precedes it aimed at whatever else on that
# managed instance happened to be called `agledger`.
RUNTIME_ROLE=""
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  # psql specifically: the drop and recreate run against the maintenance
  # database on the customer's server, and psql is not version-fussy, so any
  # recent one works.
  #
  # pg_restore is not in this check. It has no server-version gate at all —
  # what it refuses is an ARCHIVE written by a newer pg_dump than itself — so
  # it goes through pg_client_run, which picks the host binary when it is at
  # least the server's major and a container client at that major otherwise.
  # That is the right client whenever the archive came from this server, which
  # is every ordinary restore. Restoring an archive from a NEWER server than
  # the target, on a host with no client of its own, is the case that picks a
  # client too old to read the file; install a matching client there.
  command -v psql &>/dev/null \
    || die "psql is required for an external-database restore. Install PostgreSQL client tools."

  # Parsed in a subshell so the runtime connection's variables cannot linger in
  # the environment the restore connection then runs under.
  RUNTIME_IDENTITY="$(pg_env_from_url "${DATABASE_URL}" >/dev/null \
    && printf '%s\n%s\n%s\n%s\n' "${PGDATABASE:-}" "${PGUSER:-}" "${PGHOST:-}" "${PGPORT:-5432}")" \
    || die "DATABASE_URL is not a postgres:// URL."
  TARGET_DB="$(sed -n 1p <<<"${RUNTIME_IDENTITY}")"
  RUNTIME_ROLE="$(sed -n 2p <<<"${RUNTIME_IDENTITY}")"
  RUNTIME_HOST="$(sed -n 3p <<<"${RUNTIME_IDENTITY}")"
  RUNTIME_PORT="$(sed -n 4p <<<"${RUNTIME_IDENTITY}")"
  [[ -n "${TARGET_DB}" ]] || die "DATABASE_URL names no database (expected postgres://user:pass@host:port/DBNAME)."

  # Use DATABASE_URL_MIGRATE if available (owner role for DDL), else DATABASE_URL.
  #
  # The connection moves into the environment: it keeps the password out of
  # argv, and it is what makes `-d postgres` later reach the maintenance
  # database on the customer's server. Passed as a positional alongside -d, the
  # URL is consumed as a *username* and the drop/recreate silently runs against
  # libpq's defaults instead.
  RESTORE_URL="${DATABASE_URL_MIGRATE:-${DATABASE_URL}}"
  pg_env_from_url "${RESTORE_URL}" || die "DATABASE_URL_MIGRATE is not a postgres:// URL."

  # The two URLs must name the same database on the same server. Only the name
  # was ever compared, and the name is the half that matches by accident: the
  # engine's default is `agledger` on every install, so a DATABASE_URL_MIGRATE
  # left pointing at a different host — a copy-paste from another environment,
  # a stale line after a migration — passes a name check, passes the
  # is-this-an-AGLedger-database check (it IS one), and gets dropped. The
  # backup is read from DATABASE_URL and the drop is issued on
  # DATABASE_URL_MIGRATE, so the two being different servers means destroying
  # one install and not restoring the other, with nothing in the run naming the
  # host it hit.
  if ! pg_endpoints_match "${PGHOST:-}" "${PGPORT:-}" "${RUNTIME_HOST}" "${RUNTIME_PORT}"; then
    log "DATABASE_URL_MIGRATE points at ${PGHOST:-?}:${PGPORT:-5432}."
    log "DATABASE_URL points at ${RUNTIME_HOST}:${RUNTIME_PORT}."
    log "The restore reads the backup for one install and would DROP the database on the other."
    die "Refusing to restore across two servers. Point both URLs at the same PostgreSQL server."
  fi
  if [[ -n "${PGDATABASE:-}" && "${PGDATABASE}" != "${TARGET_DB}" ]]; then
    die "DATABASE_URL_MIGRATE names database \"${PGDATABASE}\" but DATABASE_URL names \"${TARGET_DB}\". They must be the same database."
  fi
else
  TARGET_DB="${POSTGRES_DB}"
fi

# --- Confirmation ---

if [[ "${NON_INTERACTIVE}" != "true" ]]; then
  echo ""
  echo "  WARNING: This will REPLACE all data in the database."
  echo "  Backup file: ${TARBALL}"
  if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
    # ${PGHOST}/${PGPORT} and not the redacted DATABASE_URL: the drop runs on
    # the connection the block above resolved, and the last human checkpoint
    # before an unrecoverable DROP has to name the server that actually
    # receives it.
    echo "  Database: External \"${TARGET_DB}\" on ${PGHOST}:${PGPORT:-5432} (role ${PGUSER:-?})"
    echo "  This DROPs and recreates \"${TARGET_DB}\" on that server."
  else
    echo "  Database: Bundled PostgreSQL (\"${TARGET_DB}\")"
  fi
  echo ""
  # Treat non-TTY stdin as implicit --non-interactive (matches upgrade.sh:143-151).
  # DR runbooks pipe into restore.sh expecting it to run; silently aborting with
  # exit 0 masks the no-op and subsequent smoke tests hit an empty database.
  if [[ ! -t 0 ]]; then
    log "WARN: non-TTY stdin detected — proceeding as if --non-interactive was passed."
  else
    read -rp "  Continue? (y/N) " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
      log "Restore cancelled."
      exit 0
    fi
  fi
fi

# --- Extract tarball ---

RESTORE_TMP="$(mktemp -d)"
# A run that stops with revocations saved and the closing notes not printed
# (pg_restore failing, a DROP or CREATE refused, a dropdb under set -e) still
# names the saved file and the replay, since the database they came from may
# already be gone.
on_restore_exit() {
  local rc=$?
  if [[ ${rc} -ne 0 && -n "${REVOCATIONS_SAVED:-}" && "${REVOCATION_NOTES_PRINTED:-false}" != true ]]; then
    log ""
    if [[ "${DATABASE_DROPPED:-false}" == true ]]; then
      log "THIS RUN READ ${REVOCATIONS_EXPORTED} REVOCATION(S) MADE AFTER THE BACKUP AND STOPPED AFTER DROPPING THE DATABASE"
      log "  THEY WERE READ OUT OF. Until they are re-applied, a key disabled since the backup authenticates again."
      revocations_saved_note "<marker id>"
    else
      log "This run stopped before dropping the database, which still holds the revocations made after the"
      log "  backup, so a re-run reads them again. The copy this run saved at ${REVOCATIONS_SAVED} is then not needed."
    fi
  fi
  rm -rf "${RESTORE_TMP}"
}
trap on_restore_exit EXIT

log "Extracting backup to ${RESTORE_TMP}..."
# backup.sh writes a gzip-compressed tar. Anything else is refused here, before
# anything is stopped, with what the file is instead of tar's own error.
if [[ "$(head -c 2 "${TARBALL}" | od -An -tx1 | tr -d ' \n')" != "1f8b" ]]; then
  log "${TARBALL} is not a gzip-compressed file, so it is not an archive backup.sh wrote (a .tar.gz)."
  log "  It begins with: $(head -c 64 "${TARBALL}" | tr -c '[:print:]' '.')"
  log "  Point this script at a .tar.gz backup.sh wrote; they are under $(backup_root)."
  refuse_untouched
fi
# A gzip file that is damaged, most often a copy cut short, is refused with
# gzip's own reason rather than as the wrong kind of file.
if ! GZIP_TEST_ERR="$(gzip -t "${TARBALL}" 2>&1)"; then
  log "${TARBALL} is a gzip-compressed file, and it is damaged: ${GZIP_TEST_ERR}"
  log "  An interrupted copy leaves this. Copy the archive again from where backup.sh wrote it ($(backup_root))."
  refuse_untouched
fi
if ! tar -xzf "${TARBALL}" -C "${RESTORE_TMP}"; then
  log "${TARBALL} is gzip-compressed but is not a tar archive tar can read; the lines above say where it stopped."
  refuse_untouched
fi

# Find the extracted directory (timestamp-named)
RESTORE_DIR=$(find "${RESTORE_TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -d "${RESTORE_DIR}" ]] || die "No directory found in backup tarball."
[[ -f "${RESTORE_DIR}/db.dump" ]] || die "db.dump not found in backup."

# Read the dump before touching the database. Everything below this line stops
# the stack and drops the database; a dump that pg_restore refuses discovered
# after that point leaves the operator with neither a running Server nor their
# data. backup.sh checks the same magic when it writes the file, so this catches
# an archive backup.sh did not write, or one damaged in storage or transit.
if ! pg_dump_magic_ok "${RESTORE_DIR}/db.dump"; then
  PREFIX_HINT="$(pg_dump_prefix_hint "${RESTORE_DIR}/db.dump")"
  log "This backup cannot be restored: db.dump is not a PostgreSQL custom-format archive."
  if [[ -z "${PREFIX_HINT}" ]]; then
    log "The file is empty. There is nothing in this tarball to restore."
  else
    log "It begins with: ${PREFIX_HINT}"
    log ""
    log "If that line is a log message rather than binary, this is a backup that captured"
    log "its own status output ahead of the archive, and the archive after it is intact."
    log "Rebuild the tarball with the prefix stripped, then restore that:"
    log ""
    log "  WORK=\$(mktemp -d) && tar -xzf '${TARBALL}' -C \"\${WORK}\""
    log "  D=\$(find \"\${WORK}\" -mindepth 2 -maxdepth 2 -name db.dump)"
    log "  python3 -c \"import sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[1],'wb').write(d[d.index(b'PGDMP'):])\" \"\${D}\""
    log "  tar -czf repaired.tar.gz -C \"\${WORK}\" \$(basename \$(dirname \"\${D}\"))"
    log "  $0 repaired.tar.gz"
    log ""
    log "If it is binary, or the archive still will not read, the file was damaged in"
    log "storage or transit and there is nothing to recover from it — use another backup."
  fi
  refuse_untouched
fi

# --- The version this backup came from: decide ---
#
# A restore that puts back the data and leaves the install on the release it is
# rolling back FROM is not a rollback: the restart re-runs migrate, the newer
# release's migration goes on top of the older dump, and `/health/ready` reports
# the release the operator had just tried to leave.
#
# So the version travels IN the archive (backup.sh writes backup-metadata), and
# the decision is made HERE, above the drop, with the image fetched before
# anything is destroyed. A registry that cannot be reached is the ordinary
# air-gap case, and discovering it after the database is gone leaves an operator
# holding a rolled-back dump under a release that will migrate straight over it.
# Every other precondition in this script is hoisted the same way, for the same
# reason.

# Fetch an image this run needs before anything is stopped or dropped. The same
# authentication install.sh and upgrade.sh perform before their own pulls:
# without it a private-registry install fails the pull with `no basic auth
# credentials`, and none of the ways forward the callers print is the
# `docker login` that fixes it.
#
# The registry is read off the reference being pulled, not off AGLEDGER_IMAGE:
# the cluster recipe names its image through AGLEDGER_IMAGE_PIN alone.
fetch_before_drop() {
  local ref="$1" registry
  docker image inspect "${ref}" >/dev/null 2>&1 && return 0
  if registry="$(registry_host_from_image "${ref}")"; then
    log "Authenticating with ${registry} before the pull..."
    AGLEDGER_IMAGE="${ref}" ecr_login
  fi
  log "Fetching ${ref} before anything is dropped..."
  docker pull "${ref}"
}

# The decision itself is a pure function so it can be driven in the deploy
# guards without a database, a registry or a Docker daemon. Everything with a
# side effect is either here (the pull) or in the applying half further down
# (the .env write, once the data is actually back).
#
# Prints one word, and for `pin` the image reference to land on:
#   unknown   the archive carries no version record
#   same      the backup and the install are on one version
#   keep      they differ and --keep-version was passed
#   cross     --keep-version was passed, the backup is 1.x and the install is
#             2.x or later: the 2.x migration refuses a 1.x database, so staying
#             on the installed release can only end in a stack that will not start
#   pin <ref> they differ and the install moves back to the backup's version
restore_version_plan() {
  local backup_version="$1" installed_version="$2" keep_version="$3" image_pin="$4" image="$5"
  local installed_major="${installed_version%%.*}"
  if [[ -z "${backup_version}" ]]; then
    echo "unknown"
  elif [[ "${backup_version}" == "${installed_version}" ]]; then
    echo "same"
  elif [[ "${keep_version}" == "true" && "${backup_version%%.*}" == "1" \
    && "${installed_major}" =~ ^[0-9]+$ ]] && (( 10#${installed_major} >= 2 )); then
    echo "cross"
  elif [[ "${keep_version}" == "true" ]]; then
    echo "keep"
  else
    printf 'pin %s\n' "${image_pin:-${image}:${backup_version}}"
  fi
}

BACKUP_VERSION="$(get_env_value agledger_version "${RESTORE_DIR}/backup-metadata")"
BACKUP_IMAGE_PIN="$(get_env_value agledger_image_pin "${RESTORE_DIR}/backup-metadata")"
BACKUP_PROJECT="$(get_env_value compose_project "${RESTORE_DIR}/backup-metadata")"
SERVING_VERSION="${INSTALLED_VERSION}"
# matched, mismatch, or unrecorded. Three, not two: an archive that carries no
# version record is not a mismatch, because nothing here knows whether it is
# one, and a run that claimed otherwise would be inventing the fact the
# operator needs.
VERSION_OUTCOME=matched

# This archive belongs to another install on this host. Said, not refused:
# cloning one install's data into a second stack is a real thing to do, and the
# operator is the only one who knows which this is.
THIS_PROJECT="$(compose_project_name)"
if [[ -n "${BACKUP_PROJECT}" && "${BACKUP_PROJECT}" != "${THIS_PROJECT}" ]]; then
  log "NOTE: this backup was taken by compose project '${BACKUP_PROJECT}'; this install is '${THIS_PROJECT}'."
  log "      Its data, its credentials and the version below are that install's, not this one's."
fi

read -r VERSION_PLAN TARGET_REF <<< "$(restore_version_plan \
  "${BACKUP_VERSION}" "${INSTALLED_VERSION}" "${KEEP_VERSION}" "${BACKUP_IMAGE_PIN}" "${AGLEDGER_IMAGE}")"

if [[ "${VERSION_PLAN}" == "unknown" ]]; then
  MARKER_VERSION="$(read_pre_upgrade_marker)"
  VERSION_OUTCOME=unrecorded
  log "This backup carries no version record: the archives the chart's backup Job writes"
  log "  do not include one."
  log "  Nothing here can tell which release its schema came from, so it is restored onto"
  log "  ${SERVING_VERSION}, and that release's migration runs over this dump before anything starts."
  # Only a version that could be installed. The marker records whatever the
  # upgrade could establish, and that includes the literal string `unknown`.
  if is_concrete_version "${MARKER_VERSION}"; then
    log "  The rollback marker in $(backup_root) names ${MARKER_VERSION}. If this archive is that"
    log "  upgrade's pre-upgrade backup, finish the rollback with:"
    log "    ./scripts/install.sh --version ${MARKER_VERSION}"
  fi
elif [[ "${VERSION_PLAN}" == "cross" ]]; then
  log "This backup came from ${BACKUP_VERSION}, and --keep-version would keep the install on ${SERVING_VERSION}."
  log "  ${SERVING_VERSION} does not upgrade a 1.x database: its migration refuses the restored dump, and the"
  log "  stack would not start on it. Two ways forward:"
  log "  - re-run without --keep-version to return this install to ${BACKUP_VERSION} with its data; or"
  log "  - restore the archive into a ${BACKUP_VERSION} install, and run ${SERVING_VERSION} on a new, empty database."
  refuse_untouched
elif [[ "${VERSION_PLAN}" == "same" ]]; then
  log "Backup and install are both on ${BACKUP_VERSION}."
elif [[ "${VERSION_PLAN}" == "keep" ]]; then
  VERSION_OUTCOME=mismatch
  log "This backup came from ${BACKUP_VERSION}; --keep-version keeps the install on ${SERVING_VERSION}."
  log "  The restart re-applies ${SERVING_VERSION}'s migrations over a ${BACKUP_VERSION} dump."
  log "  To land on ${BACKUP_VERSION} instead: ./scripts/install.sh --version ${BACKUP_VERSION}"
else
  log "This backup came from ${BACKUP_VERSION}; the install is on ${SERVING_VERSION}."
  log "This restore returns the install to ${BACKUP_VERSION}, so the dump and the schema agree."
  if ! fetch_before_drop "${TARGET_REF}"; then
    log ""
    log "${TARGET_REF} is not on this host and could not be pulled, so this restore cannot"
    log "finish on ${BACKUP_VERSION}. Two ways forward:"
    log "  - make that image reachable and re-run this command: authenticate to the"
    log "    registry ('docker login $(registry_host_from_image "${TARGET_REF}" || echo docker.io)'), or 'docker load' it from an"
    log "    air-gap bundle; or"
    if [[ "$(restore_version_plan "${BACKUP_VERSION}" "${INSTALLED_VERSION}" true "" "")" != "cross" ]]; then
      log "  - re-run with --keep-version to restore the data onto ${SERVING_VERSION}, which"
      log "    re-applies ${SERVING_VERSION}'s migrations over a ${BACKUP_VERSION} dump."
    fi
    refuse_untouched
  fi
fi

# The image the install runs now, which every one-off container above the
# version move runs in: the revocation read, the privilege check, and (for any
# plan but pin) the migration and the post-restore steps. A host restoring into
# a cluster has never pulled it, and a run that found that out at the first
# `docker compose run` would find it with the API and Worker already stopped.
SERVING_REF="${AGLEDGER_IMAGE_PIN:-${AGLEDGER_IMAGE}:${INSTALLED_VERSION}}"
if ! fetch_before_drop "${SERVING_REF}"; then
  log ""
  log "${SERVING_REF} is not on this host and could not be pulled. It is the image this restore runs"
  log "its privilege check, migration and post-restore steps in. Make it reachable and re-run: authenticate"
  log "to its registry ('docker login $(registry_host_from_image "${SERVING_REF}" || echo docker.io)'), or 'docker load' it from an"
  log "air-gap bundle."
  refuse_untouched
fi


# --- Is this database ours to drop? ---
#
# Asked here, above the stop, for the same reason the dump is read here: every
# way this can refuse leaves the operator with a Server that never went down.
# Below this line the API and Worker are stopped, and "nothing was changed" is
# false from there on.
#
# The SQL arrives on stdin, not through -c: psql performs :var interpolation
# only on input it reads, so with -c the `:"db"` reaches the server verbatim and
# every one of these statements is a syntax error. ON_ERROR_STOP comes with it,
# because psql reading a script exits 0 after an ERROR unless it is set — which
# would leave the `|| die` guards further down never firing.
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  PROBE_ERR="${RESTORE_TMP}/probe.err"

  # "Answered: absent" and "could not ask" are different answers, and only the
  # first means it is safe to carry on. Collapsing them let a connection reset
  # during a failover — the situation a restore happens in — skip the guard
  # below entirely and go straight to a DROP on a fresh connection.
  if ! DB_PRESENT="$(psql -qX -v ON_ERROR_STOP=1 -d postgres -tA -v db="${TARGET_DB}" \
      <<<"SELECT count(*) FROM pg_database WHERE datname = :'db';" 2>"${PROBE_ERR}")"; then
    log "Could not reach ${PGHOST}:${PGPORT:-5432} as \"${PGUSER:-?}\" to look up \"${TARGET_DB}\":"
    while IFS= read -r probe_line; do log "  ${probe_line}"; done < "${PROBE_ERR}"
    refuse_untouched "Fix the connection and re-run."
  fi

  if [[ "${DB_PRESENT}" == "1" ]]; then
    # Refuse to drop a database that is not this install's. On a shared managed
    # instance — the whole point of external-database mode — the name in
    # DATABASE_URL can be anything, and DROP DATABASE is not undoable.
    #
    # An EMPTY database passes: that is what a run interrupted between CREATE
    # DATABASE and the end of pg_restore leaves behind, and refusing it would
    # send the operator to --force on the one occasion the real database is
    # already gone.
    if ! TARGET_SHAPE="$(psql -qX -v ON_ERROR_STOP=1 -d "${TARGET_DB}" -tA <<<"
        SELECT CASE
          WHEN to_regclass('public.records') IS NOT NULL THEN 'agledger'
          WHEN NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                           WHERE n.nspname = 'public' AND c.relkind IN ('r','p')) THEN 'empty'
          ELSE 'other'
        END;" 2>"${PROBE_ERR}")"; then
      log "Could not read \"${TARGET_DB}\" on ${PGHOST} to check it is this install's database:"
      while IFS= read -r probe_line; do log "  ${probe_line}"; done < "${PROBE_ERR}"
      log "That is a connection or privilege problem, not a wrong database name."
      refuse_untouched "Fix the connection and re-run."
    fi

    if [[ "${TARGET_SHAPE}" == "other" ]]; then
      if [[ "${FORCE}" == "true" ]]; then
        log "WARN: --force — \"${TARGET_DB}\" on ${PGHOST} holds tables that are not this install's."
        log "      Dropping it anyway, as asked. This cannot be undone."
      else
        log "Database \"${TARGET_DB}\" on ${PGHOST} holds tables but no public.records, so it does"
        log "not look like an AGLedger database. Restoring drops it and everything in it."
        log "If that is genuinely the target, re-run with --force."
        refuse_untouched ""
      fi
    fi

    # One URL on an install that serves as a second role: see
    # restore_role_verdict. The database about to be dropped is the only thing
    # here that knows which role the Server connects as, so it is asked now.
    if [[ "${TARGET_SHAPE}" == "agledger" ]]; then
      if ! PGBOSS_OWNER="$(psql -qX -v ON_ERROR_STOP=1 -d "${TARGET_DB}" -tA \
          <<<"SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'pgboss';" 2>"${PROBE_ERR}")"; then
        log "Could not read which role owns the pgboss schema in \"${TARGET_DB}\" on ${PGHOST}:"
        while IFS= read -r probe_line; do log "  ${probe_line}"; done < "${PROBE_ERR}"
        refuse_untouched "Fix the connection and re-run."
      fi
      MIGRATE_URL_GIVEN=false
      [[ -n "${DATABASE_URL_MIGRATE:-}" ]] && MIGRATE_URL_GIVEN=true
      if [[ "$(restore_role_verdict "${MIGRATE_URL_GIVEN}" "${PGUSER:-}" "${PGBOSS_OWNER}")" == split ]]; then
        log "\"${TARGET_DB}\" is served by a second role: its pgboss schema belongs to \"${PGBOSS_OWNER}\","
        log "  and this run was given one URL, as \"${PGUSER:-?}\". With one URL the restore takes \"${PGUSER:-?}\""
        log "  for the runtime role as well, so the pgboss schema and the database grants would go to it,"
        log "  and a Server connecting as \"${PGBOSS_OWNER}\" would stop at boot on"
        log "  'permission denied for schema pgboss'."
        log ""
        log "  Pass both URLs, the way the Server takes them:"
        log "    DATABASE_URL          as \"${PGBOSS_OWNER}\", the role the API and Worker connect as"
        log "    DATABASE_URL_MIGRATE  as \"${PGUSER:-?}\", the owner the restore and the migration run as"
        log "  If this install now serves as \"${PGUSER:-?}\" on purpose, set DATABASE_URL_MIGRATE to the"
        log "  same URL as DATABASE_URL to say so."
        refuse_untouched
      fi
    fi
  fi
fi

# --- Can the restoring role rebuild the schema? ---
#
# The dump carries `agledger_block_audit_drop`, the sql_drop event trigger that
# is layer 2 of the tamper model (the DDL guard), and CREATE EVENT TRIGGER is superuser-only.
# install.sh asks this before it installs anything and refuses with "Nothing has
# been installed." A restore rebuilds the same schema with the same role and has
# strictly more to lose: by the time pg_restore reaches the statement, the
# database it would go back to is already dropped, and pg_restore does not stop
# there. It reports the refusal among its "errors ignored on restore", puts every
# row back, and exits 1, leaving the chain present with the trigger that protects
# it absent.
#
# The grant lapses on its own. deploy/README.md makes this argument for
# upgrade.sh ("a role dropped and recreated by a rotation policy comes back
# without its agledger_app membership"), and a restore is the stronger case, not
# the weaker one: it routinely runs against a REBUILT server whose roles were
# recreated by whatever provisioning ran, with the operator mid-incident.
#
# External path only. The bundled path restores as POSTGRES_USER, which is the
# superuser of its own container.
#
# `-d postgres`, not the target: the maintenance database is reachable whether or
# not the target exists, and the answer is cluster-wide either way.
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  PRIV_ERR="${RESTORE_TMP}/privilege.err"
  PRIV_PROBE="$(psql -qX -v ON_ERROR_STOP=1 -d postgres -tA \
    <<<"$(audit_event_trigger_probe_sql)" 2>"${PRIV_ERR}")" || PRIV_PROBE=""

  case "$(audit_event_trigger_verdict "${PRIV_PROBE}")" in
  ok)
    log "Restore privileges: sufficient for the audit-chain event trigger."
    ;;
  refuse)
    log "The restoring role \"${PGUSER:-?}\" cannot create an event trigger, so the restore would"
    log "rebuild this database without the audit chain's own protection."
    log ""
    while IFS= read -r priv_line; do log "  ${priv_line}"; done < <(audit_event_trigger_remedy "${PGUSER:-<migrate role>}")
    log ""
    log "pg_restore would not stop on it. It reports the refusal, restores every row anyway and"
    log "exits 1, so the rows come back and the trigger does not."
    refuse_untouched "Grant the privilege and re-run."
    ;;
  *)
    # Could not ask. That is not the same answer as "no", and it is not grounds
    # to drop the database on a guess either: this is the connection a failover
    # just reset.
    log "Could not determine whether \"${PGUSER:-?}\" can create the audit-chain event trigger."
    [[ -s "${PRIV_ERR}" ]] && while IFS= read -r priv_line; do log "  ${priv_line}"; done < "${PRIV_ERR}"
    refuse_untouched "Fix the connection and re-run."
    ;;
  esac
fi

# --- Can this run's pg_restore read the archive? ---
#
# The restore below reads db.dump with the same pg_restore this asks, after the
# drop. A client older than the pg_dump that wrote the archive refuses it
# ("unsupported version in file header"), and finding that out after the drop
# leaves neither the old database nor the new one. `--list` reads the archive's
# header and table of contents and connects nowhere, so it is asked here, while
# nothing has been stopped. The bundled path runs it in the postgres image as a
# one-off, the image the restore itself execs into.
ARCHIVE_READ_ERR="${RESTORE_TMP}/archive-read.err"
ARCHIVE_READABLE=false
if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint pg_restore postgres --list \
    < "${RESTORE_DIR}/db.dump" > /dev/null 2> "${ARCHIVE_READ_ERR}" && ARCHIVE_READABLE=true
else
  ( pg_client_run pg_restore --list ) \
    < "${RESTORE_DIR}/db.dump" > /dev/null 2> "${ARCHIVE_READ_ERR}" && ARCHIVE_READABLE=true
fi
if [[ "${ARCHIVE_READABLE}" != true ]]; then
  log "pg_restore cannot read ${TARBALL}'s db.dump, so the restore would drop the database and then fail:"
  while IFS= read -r read_line; do log "  ${read_line}"; done < "${ARCHIVE_READ_ERR}"
  log "  An archive written by a newer pg_dump than this pg_restore is the usual cause. Install a"
  log "  PostgreSQL client at least as new as the server the backup was taken from, or run this from a"
  log "  host that has one, and re-run."
  refuse_untouched
fi

# --- Stop application services ---

# A cluster restore has no application services on this host: the cluster's
# Deployments are scaled to 0 by the Kubernetes runbook before this runs.
if [[ "${CLUSTER_RESTORE}" != true ]]; then
  log "Stopping application services..."
  "${COMPOSE[@]}" stop agledger-api agledger-worker 2>/dev/null || true
  "${COMPOSE[@]}" rm -f agledger-migrate 2>/dev/null || true
fi

# The bundled database, up and answering. Started here, before the revocation
# read below, because a stack that was stopped when this ran has no database to
# read them from, and the read would find nothing to carry across from the
# database it is about to replace.
ensure_bundled_postgres() {
  log "Ensuring postgres is running..."
  "${COMPOSE[@]}" up -d postgres

  local wait=0
  while [[ ${wait} -lt 30 ]]; do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER}" &>/dev/null; then
      return 0
    fi
    sleep 1
    wait=$((wait + 1))
  done
  die "PostgreSQL did not become ready in 30 seconds."
}
if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
  ensure_bundled_postgres
fi

# --- Revocations the restore would undo ---
#
# A revocation is a row in the same database, so the restore undoes every one
# made after the backup: a key disabled since then authenticates again, a
# revoked certificate or peer is honoured again, a consumed single-use token can
# be replayed. The database about to be dropped is the only record of them, so
# they are read out of it now, and re-applied by the post-restore step once the
# restored schema is current. Bounded by the backup's own creation instant,
# which backup.sh and the chart's backup Job both take before the dump starts;
# an archive without one exports every revocation, which the replay applies
# harmlessly to rows the backup already held as revoked.
#
# That record exists only in the very database the backup was dumped from,
# carried forward to now. A fresh host's own database, a standby restored from
# an earlier backup, and the database a previous attempt at this restore left
# behind all read fine and hold none of the revocations the restore undoes, so a
# count of 0 from them would say nothing was revoked when nothing could be
# known. The archive records which database it was dumped from (database_token
# in backup-metadata, see database_token_sql) and the export reads nothing out
# of any other. REVOCATION_OUTCOME is then other_database (compared, and it is
# not that database) or unproven (nothing could be compared), and the closing
# notes handle both as they do a database that could not be read.
REVOCATIONS_FILE="${RESTORE_TMP}/revocations.ndjson"
REVOCATION_OUTCOME=unavailable
REVOCATION_SUMMARY=""
REVOCATIONS_EXPORTED=0
REVOCATION_SOURCE_NOTE=""
BACKUP_CREATED_AT="$(get_env_value created_at "${RESTORE_DIR}/backup-metadata" 2>/dev/null || true)"
BACKUP_DATABASE_TOKEN="$(get_env_value database_token "${RESTORE_DIR}/backup-metadata" 2>/dev/null || true)"
BACKUP_WAL_LSN="$(get_env_value wal_lsn "${RESTORE_DIR}/backup-metadata" 2>/dev/null || true)"
: > "${REVOCATIONS_FILE}"

if ! is_database_token "${BACKUP_DATABASE_TOKEN}" || ! is_wal_lsn "${BACKUP_WAL_LSN}"; then
  REVOCATION_OUTCOME=unproven
  REVOCATION_SOURCE_NOTE="The archive does not record both database_token and wal_lsn, so nothing can show which database it was dumped from, or that the one about to be replaced carried on from it: it was written by a backup.sh or chart backup Job that did not record them, or by one whose database would not report them."
fi

if [[ "${REVOCATION_OUTCOME}" == unavailable ]]; then
  log "Reading revocations made after the backup out of the database about to be replaced..."
  log "  The backup was dumped from database ${BACKUP_DATABASE_TOKEN} (cluster system identifier:OID); any other holds none of them."
  SINCE_ARGS=(--database-token "${BACKUP_DATABASE_TOKEN}" --wal-lsn "${BACKUP_WAL_LSN}")
  [[ -n "${BACKUP_CREATED_AT}" ]] && SINCE_ARGS+=(--since "${BACKUP_CREATED_AT}")
  # NODE_OPTIONS cleared on every one-off `node` this script runs: it reaches every
  # node process in the container, `run` inherits the service's `env_file: .env`,
  # and these invocations override the image argv so they carry neither
  # `--permission` nor `--allow-fs-read`. An operator who set the SIEM file-sink
  # grant (or an APM `--import`) in `.env` rather than on the worker service would
  # fail them at pre-execution with ERR_MISSING_OPTION, before any code runs.
  # NODE_EXTRA_CA_CERTS, which is how a CA bundle reaches this image, is untouched.
  #
  # On the bundled path it reads as the owner, not as agledger_app. The runtime
  # role's login is put in place by the migration run that follows the restore,
  # so against the database about to be replaced it may not work yet: a
  # pre-split install left the role NOLOGIN, and reconcile_env_file may have just
  # minted its password. A failed read here is only a WARN, and it would drop
  # the revocations to replay without saying why. The URL reaches compose
  # through its environment, which is where the service's DATABASE_URL default
  # is interpolated from, so it is never an argument.
  REVOCATION_READ_URL="${DATABASE_URL:-}"
  if [[ "${USES_BUNDLED_PG}" == "true" ]]; then
    REVOCATION_READ_URL="postgresql://${POSTGRES_USER:-agledger}:$(get_env_value POSTGRES_PASSWORD "${COMPOSE_DIR}/.env")@postgres:5432/${POSTGRES_DB:-agledger}"
  fi
  if DATABASE_URL="${REVOCATION_READ_URL}" "${COMPOSE[@]}" run --rm --no-deps -T -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api \
       dist/scripts/post-restore.js --export-revocations "${SINCE_ARGS[@]}" 2>&1 \
     | tee "${RESTORE_TMP}/revocations-export.log" \
     | sed -n 's/^REVOCATION //p' > "${REVOCATIONS_FILE}"; then
    REVOCATIONS_EXPORTED="$(grep -c . "${REVOCATIONS_FILE}" || true)"
    REVOCATION_OUTCOME=exported
    if grep -q '^REVOCATION_SOURCE_OTHER ' "${RESTORE_TMP}/revocations-export.log"; then
      REVOCATION_OUTCOME=other_database
      REVOCATION_SOURCE_NOTE="$(sed -n 's/^REVOCATION_SOURCE_OTHER //p' "${RESTORE_TMP}/revocations-export.log" | tail -1)"
    elif grep -q '^REVOCATION_SOURCE_UNKNOWN ' "${RESTORE_TMP}/revocations-export.log"; then
      REVOCATION_OUTCOME=unproven
      REVOCATION_SOURCE_NOTE="$(sed -n 's/^REVOCATION_SOURCE_UNKNOWN //p' "${RESTORE_TMP}/revocations-export.log" | tail -1)"
    fi
    if [[ "${REVOCATION_OUTCOME}" != exported ]]; then
      REVOCATIONS_EXPORTED=0
      : > "${REVOCATIONS_FILE}"
    elif [[ -z "${BACKUP_CREATED_AT}" ]]; then
      log "  The archive records no creation instant, so this read is not bounded by the backup: it took"
      log "  every revocation the database holds (${REVOCATIONS_EXPORTED}), made before the backup or after it."
      log "  The replay re-applies each one; a credential the backup already holds as revoked stays revoked."
    else
      log "  ${REVOCATIONS_EXPORTED} revocation(s) made after ${BACKUP_CREATED_AT}."
    fi
    if [[ "${REVOCATION_OUTCOME}" == exported ]]; then
      log "  This database answers as the one the backup was dumped from. A physical copy of it taken after"
      log "  the backup (a snapshot, a point-in-time restore, a clone) answers the same, and holds none of the"
      log "  revocations made on the original after the copy: if this is such a copy, compare the list"
      log "  post-restore.js --list-active-credentials prints against your own record of revocations."
    fi
  else
    log "WARN: could not read revocations out of the current database (see above). If this host has no"
    log "      previous database, that is expected; the closing notes say what to compare instead."
    : > "${REVOCATIONS_FILE}"
  fi
fi
if [[ "${REVOCATION_OUTCOME}" == other_database || "${REVOCATION_OUTCOME}" == unproven ]]; then
  log "NOTE: no revocations were read. ${REVOCATION_SOURCE_NOTE}"
  log "      A credential revoked after the backup comes back live; the closing notes say what to compare instead."
fi

# --- Keep the revocations past this run ---
#
# The export above is in this run's temp directory, which the EXIT trap
# removes, and the database it came from is about to be dropped. A run that
# stops anywhere below (pg_restore, the DROP or CREATE, the migration) would
# take the only copy with it, and a re-run cannot read them again, so they are
# written beside the archives now, before anything is dropped. A cluster
# restore keeps them in its post-restore input directory instead.
if [[ "${CLUSTER_RESTORE}" != true && "${REVOCATION_OUTCOME}" == exported && -s "${REVOCATIONS_FILE}" ]]; then
  REVOCATIONS_SAVED="$(backup_root)/revocations-${THIS_PROJECT}-${RESTORE_MARKER_SUFFIX}.ndjson"
  if ! mkdir -p "$(backup_root)" \
     || ! ( umask 077 && cp "${REVOCATIONS_FILE}" "${REVOCATIONS_SAVED}" ) \
     || ! chmod 600 "${REVOCATIONS_SAVED}"; then
    REVOCATIONS_SAVED=""
    die "Could not save the revocations this run read to $(backup_root), and the database they came from is the only other copy. Nothing was dropped; the API and Worker are stopped, and '${COMPOSE[*]} up -d' starts them again."
  fi
  log "  Saved them to ${REVOCATIONS_SAVED}; the post-restore step replays them and then removes the file."
fi

# --- The cluster's post-restore input ---
#
# On a cluster the steps after the migration run in the chart's post-restore
# Job, with the release's configuration, and this is what the Job reads: the
# restore's marker id, when it started, the archive, and the revocations just
# exported, gzipped because the Secret the runbook carries it in holds 1 MiB and
# an archive with no creation instant exports every revocation the database
# holds. Written before the drop, because the export is
# the only copy of those revocations once the database is gone, and a run that
# stops anywhere below still names this directory.
POST_RESTORE_INPUT=""
POST_RESTORE_JOB=""
if [[ "${CLUSTER_RESTORE}" == true ]]; then
  POST_RESTORE_INPUT="$(backup_root)/post-restore-${RESTORE_STARTED_AT//[^0-9]/}-$$"
  POST_RESTORE_JOB="agledger-post-restore-${RESTORE_STARTED_AT//[^0-9]/}-$$"
  if ! write_post_restore_input "${POST_RESTORE_INPUT}"; then
    die "Could not write the post-restore input to ${POST_RESTORE_INPUT}. Nothing was dropped."
  fi
  log "The post-restore Job's input is in ${POST_RESTORE_INPUT}."
fi

# --- Restore PostgreSQL ---

# Run pg_restore (however the caller reaches it) against the extracted dump,
# and decide what a non-zero exit means.
#
# The dump's privileges are restored, not discarded. They are the privilege set
# the schema installed — the DML grants to agledger_app, the ALTER DEFAULT
# PRIVILEGES that keep later migrations reachable, and the append-only REVOKEs
# that hold the runtime role out of UPDATE/DELETE on the audit chain. Dropping
# them with --no-acl left a correctly-provisioned-looking role holding nothing,
# and the first thing the operator saw was a crash-looping container.
#
# pg_restore does not stop on a statement it cannot run: it reports each one,
# restores everything else, and exits 1. So a GRANT naming a role this server
# does not have costs privileges, not data, and must not be read as a failed
# restore — while anything else must. The two are told apart by what the
# failing statements were.
pg_restore_from_dump() {
  local rc=0
  set +e
  "$@" < "${RESTORE_DIR}/db.dump" 2>&1 | tee "${RESTORE_TMP}/pg_restore.log"
  rc=${PIPESTATUS[0]}
  set -e
  [[ ${rc} -eq 0 ]] && return 0

  local errors privilege_errors trigger_errors
  errors=$(grep -c '^pg_restore: error: ' "${RESTORE_TMP}/pg_restore.log" || true)
  privilege_errors=$(grep -cE '^Command was: (GRANT|REVOKE|ALTER DEFAULT PRIVILEGES)' "${RESTORE_TMP}/pg_restore.log" || true)
  # A refused CREATE EVENT TRIGGER is a third statement class that costs
  # privileges rather than data, and it was not counted as one. It is not a
  # GRANT, so `errors` exceeded `privilege_errors`, the restore was declared
  # failed, and the operator got "the database is in whatever state the output
  # above describes" with every row already back and nothing naming the trigger.
  # Counted here so the check further down is reached, names what is missing, and
  # prints the single statement that repairs it.
  trigger_errors=$(grep -c '^Command was: CREATE EVENT TRIGGER agledger_block_audit_drop' "${RESTORE_TMP}/pg_restore.log" || true)

  if [[ ${errors} -gt 0 && ${errors} -eq ${privilege_errors} ]]; then
    log "WARN: every row restored, but ${errors} privilege statement(s) in the backup could not be"
    log "      applied — see the GRANT/REVOKE lines above. This is normal when restoring onto a"
    log "      server that does not carry the same roles (a cross-server DR, or a single-role"
    log "      install). The runtime-role check below decides whether this Server can serve."
    return 0
  fi

  # Same reading, with the audit-chain event trigger among the refused
  # statements. Every row is back and what is missing is a lock, so this is a
  # report rather than a failed restore. Dying here is what hid the trigger:
  # the run ended on a generic message and the operator had to read pg_restore's
  # own stderr to learn which statement was skipped.
  if [[ ${errors} -gt 0 && ${trigger_errors} -gt 0 && $((privilege_errors + trigger_errors)) -eq ${errors} ]]; then
    log "WARN: every row restored. ${privilege_errors} privilege statement(s) and the audit-chain"
    log "      event trigger could not be applied. The check immediately below names what the"
    log "      missing trigger costs and prints the statement that repairs it."
    return 0
  fi

  die "pg_restore failed (exit ${rc}). The database is in whatever state the output above describes; the backup file itself is unchanged."
}

log "Restoring PostgreSQL database..."

if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  # Connect to the target database to terminate active connections
  psql -d "${TARGET_DB}" -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = current_database() AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true

  # Drop and recreate from the 'postgres' maintenance database. Not silenced:
  # a DROP that fails leaves the CREATE to fail too, and the operator needs to
  # see which one it was. The name goes through psql's :"var" interpolation so
  # it is quoted as an identifier rather than pasted into the statement.
  psql -qX -v ON_ERROR_STOP=1 -d postgres -v db="${TARGET_DB}" <<<'DROP DATABASE IF EXISTS :"db";' \
    || die "Failed to drop \"${TARGET_DB}\" on ${PGHOST}. The role must own the database (or be superuser), and no other session may be connected to it."
  DATABASE_DROPPED=true
  psql -qX -v ON_ERROR_STOP=1 -d postgres -v db="${TARGET_DB}" <<<'CREATE DATABASE :"db";' \
    || die "Failed to recreate \"${TARGET_DB}\" on ${PGHOST}. Ensure the role has CREATEDB."

  # A new database carries no ACL at all (`datacl` is NULL, not a copy of the
  # template's), so every database-level grant the install made is gone —
  # granting on template1 would not have brought them back either. Nothing in
  # the dump carries them: pg_dump
  # of a single database does not include its pg_database ACL. The runtime role
  # needs CREATE for pg-boss to install its schema, which is the grant the
  # documented least-privilege setup makes and the one whose absence shows up
  # only as "permission denied for schema pgboss" at boot.
  if [[ -n "${RUNTIME_ROLE}" && "${RUNTIME_ROLE}" != "${PGUSER:-}" ]]; then
    psql -qX -v ON_ERROR_STOP=1 -d postgres -v db="${TARGET_DB}" -v role="${RUNTIME_ROLE}" \
      <<<'GRANT CONNECT, CREATE ON DATABASE :"db" TO :"role";' >/dev/null \
      || log "WARN: could not grant CONNECT, CREATE on \"${TARGET_DB}\" to \"${RUNTIME_ROLE}\" — the runtime-role check below reports what that costs."
  fi

  pg_restore_from_dump pg_client_run pg_restore -d "${TARGET_DB}" --no-owner
else
  # Bundled postgres — exec into the container
  ensure_bundled_postgres

  "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true

  "${COMPOSE[@]}" exec -T postgres dropdb -U "${POSTGRES_USER}" --if-exists "${POSTGRES_DB}"
  DATABASE_DROPPED=true
  "${COMPOSE[@]}" exec -T postgres createdb -U "${POSTGRES_USER}" "${POSTGRES_DB}"

  pg_restore_from_dump "${COMPOSE[@]}" exec -T postgres pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner
fi

log "PostgreSQL restore complete."

# --- Did the audit-chain event trigger come back? ---
#
# The gate above stops the ordinary way to lose it, and this is the check that
# the rows and their protection actually arrived together. It is not redundant
# with the gate. Two routes still reach here: a provider whose superuser-
# equivalent role answers the membership probe `true` and still refuses the
# statement (the probe asks about ROLE MEMBERSHIP, which is not the same
# question as the capability), and a dump that never carried the trigger,
# because it was taken from a database already in this state. Both end with
# every row restored and the DDL guard gone, which is the one outcome where a
# finished restore looks complete and is not.
#
# This reports and carries on rather than dying. The data is back and the Server
# can serve it, the repair is one statement, and stopping here would leave the
# stack down for something that is not about access to the rows. The result is
# repeated in the closing summary so it cannot scroll away behind pg_restore's
# output.
AUDIT_TRIGGER_MISSING=false
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  TRIGGER_COUNT="$(psql -qX -v ON_ERROR_STOP=1 -d "${TARGET_DB}" -tA \
    <<<"${AUDIT_EVENT_TRIGGER_PRESENT_SQL}" 2>/dev/null | tr -d '[:space:]')" || TRIGGER_COUNT=""
else
  TRIGGER_COUNT="$("${COMPOSE[@]}" exec -T postgres psql -qX -v ON_ERROR_STOP=1 \
    -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tA \
    -c "${AUDIT_EVENT_TRIGGER_PRESENT_SQL}" 2>/dev/null | tr -d '[:space:]')" || TRIGGER_COUNT=""
fi

if [[ "${TRIGGER_COUNT}" == "0" ]]; then
  AUDIT_TRIGGER_MISSING=true
  log ""
  log "WARN: the audit-chain event trigger 'agledger_block_audit_drop' is NOT on the restored"
  log "      database. Every row came back; this one protection did not."
  log ""
  log "      It is layer 2 of the tamper model, the DDL guard: it refuses an in-band DROP of"
  log "      audit_vault, every monthly audit_vault_* partition, vault_checkpoints,"
  log "      scitt_entries, org_admin_reads, org_admin_reads_checkpoints,"
  log "      org_admin_read_sequences, org_admin_read_export_manifests,"
  log "      vault_signing_keys and vault_key_statements."
  log ""
  log "      Layer 1 (the row-level DML triggers) is unaffected: UPDATE, DELETE and TRUNCATE on"
  log "      those tables are still refused. So are the signed checkpoints and, where enabled,"
  log "      the external anchors, which is what detects a chain that was tampered with rather"
  log "      than merely dropped. This is a missing lock, not a broken chain."
  log ""
  log "      Restore it as a superuser against \"${TARGET_DB}\". The function it calls came back"
  log "      with the dump, so this statement is the whole repair:"
  log ""
  while IFS= read -r ddl_line; do log "        ${ddl_line}"; done <<<"${AUDIT_EVENT_TRIGGER_DDL}"
  log ""
elif [[ -z "${TRIGGER_COUNT}" ]]; then
  log "WARN: could not confirm the audit-chain event trigger 'agledger_block_audit_drop' is"
  log "      present on the restored database. Check it with:"
  log "        SELECT evtname FROM pg_event_trigger WHERE evtname = 'agledger_block_audit_drop';"
else
  log "Audit-chain event trigger is present."
fi

# --- pgboss Schema Ownership ---
#
# `pg_restore --no-owner` makes the restoring role the owner of everything it
# writes, and the restoring role is DATABASE_URL_MIGRATE. That is right for the
# application schema, which the migrate role owns by design. It is wrong for
# `pgboss`, which pg-boss installs for itself as the RUNTIME role using the
# CREATE grant the documented least-privilege setup makes.
#
# The consequence is quiet and lands on the highest-churn tables in the
# schema, on the install that just came back from DR: the Server tunes
# autovacuum on its own job partitions at boot with
# `ALTER TABLE ... SET (autovacuum_*)`, which requires ownership, so after a
# restore that ALTER fails and the aggressive settings the product picks for
# itself are never applied. It logs a warn and continues, which is not where an
# operator finishing a restore is looking.
#
# Scoped to `pgboss` deliberately. `REASSIGN OWNED BY` would hand the migrate
# role's entire application schema to the runtime role as well, which is the
# opposite of the separation the two roles exist for.
#
# Best-effort: `ALTER ... OWNER TO` requires the current role to be a member of
# the target role, and a migrate role that is not a member of the runtime role
# cannot do it. That is a legitimate configuration, so this reports rather than
# dies, and prints the SQL a DBA can run.
if [[ "${USES_BUNDLED_PG}" == "false" && -n "${RUNTIME_ROLE}" && "${RUNTIME_ROLE}" != "${PGUSER:-}" ]]; then
  log "Returning pgboss schema ownership to \"${RUNTIME_ROLE}\"..."
  # stderr is kept, not discarded. At least three different failures reach the
  # else branch below (the migrate role is not a member of the runtime role; the
  # runtime role does not exist; an object refuses the transfer), the guidance
  # there can only name one of them, and an operator mid-DR has no other way to
  # tell which they hit.
  PGBOSS_OWNER_ERR="${RESTORE_TMP}/pgboss-owner.err"
  if psql -qX -v ON_ERROR_STOP=1 -d "${TARGET_DB}" -v role="${RUNTIME_ROLE}" >/dev/null 2>"${PGBOSS_OWNER_ERR}" <<'PGBOSS_OWNER_SQL'
-- The role travels as a session setting, NOT as a psql `:'role'` inside the
-- DO block: psql does not interpolate its variables inside a dollar-quoted
-- string, so that form reaches the server verbatim and fails with a syntax
-- error at the colon. Here `:'role'` sits outside the quoting and is
-- substituted before the statement is sent.
SELECT set_config('agledger.pgboss_owner', :'role', false);
DO $$
DECLARE
  target text := current_setting('agledger.pgboss_owner');
  obj record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'pgboss') THEN
    RETURN;
  END IF;
  EXECUTE format('ALTER SCHEMA pgboss OWNER TO %I', target);
  -- Tables, partitions, sequences, views. Indexes and constraints follow their
  -- table and cannot be altered directly.
  -- Tables first, sequences after. `ALTER SEQUENCE ... OWNER TO` is refused
  -- outright for a sequence linked to a table whose owner has not moved yet
  -- ("cannot change owner of sequence ... is linked to table ..."), and this
  -- block is atomic, so one such sequence would transfer nothing at all.
  -- Altering the table first cascades to the sequences it owns, which makes
  -- the sequence pass a no-op rather than an error. pg-boss 12 creates no
  -- sequence today; the ordering is what keeps that from mattering if it ever
  -- does.
  FOR obj IN
    SELECT c.oid::regclass AS ident, c.relkind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgboss' AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
     ORDER BY CASE c.relkind WHEN 'S' THEN 1 ELSE 0 END
  LOOP
    IF obj.relkind = 'S' THEN
      EXECUTE format('ALTER SEQUENCE %s OWNER TO %I', obj.ident, target);
    ELSIF obj.relkind = 'v' THEN
      EXECUTE format('ALTER VIEW %s OWNER TO %I', obj.ident, target);
    ELSIF obj.relkind = 'm' THEN
      EXECUTE format('ALTER MATERIALIZED VIEW %s OWNER TO %I', obj.ident, target);
    ELSE
      EXECUTE format('ALTER TABLE %s OWNER TO %I', obj.ident, target);
    END IF;
  END LOOP;
  FOR obj IN
    SELECT p.oid::regprocedure AS ident
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgboss'
  LOOP
    EXECUTE format('ALTER ROUTINE %s OWNER TO %I', obj.ident, target);
  END LOOP;
  FOR obj IN
    SELECT t.oid::regtype AS ident
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE n.nspname = 'pgboss' AND t.typtype = 'e'
  LOOP
    EXECUTE format('ALTER TYPE %s OWNER TO %I', obj.ident, target);
  END LOOP;
END $$;
PGBOSS_OWNER_SQL
  then
    log "pgboss schema is owned by \"${RUNTIME_ROLE}\" again."
  else
    log ""
    log "WARN: could not return pgboss schema ownership to \"${RUNTIME_ROLE}\"."
    [[ -s "${PGBOSS_OWNER_ERR}" ]] && sed 's/^/      /' "${PGBOSS_OWNER_ERR}" >&2
    log ""
    log "      pg_restore ran as the migrate role, so it owns pgboss now. Unless the runtime"
    log "      role holds that role's privileges, the API and the worker refuse to boot on"
    log "      'permission denied for schema pgboss', and a process left running drops every"
    log "      job it enqueues: a webhook push enqueued then is lost, and its event stays in"
    log "      GET /v1/events for the receiver to replay. The records themselves are restored."
    log "      The runtime-role check below stops this run when the role cannot use it."
    log ""
    log "      Two ways out, both against ${TARGET_DB}:"
    log ""
    log "      1. Let the migrate role do it. It needs to be a member of the runtime role:"
    log "           GRANT \"${RUNTIME_ROLE}\" TO \"${PGUSER:-<migrate role>}\";"
    log "         then re-run this script. The grant is permanent, so later restores"
    log "         handle it on their own."
    log ""
    log "      2. Drop the schema and let the Server rebuild it as itself on next start:"
    log "           DROP SCHEMA pgboss CASCADE;"
    log "         It holds queued jobs, never records, so nothing on the chain is at risk;"
    log "         work that had not been delivered yet is discarded with it."
    log ""
    log "      Moving the schema alone (ALTER SCHEMA pgboss OWNER TO ...) is NOT enough:"
    log "      the ALTER the Server runs needs ownership of each job PARTITION, not of the"
    log "      schema. And a manual fix does not survive the next restore, which drops the"
    log "      database and restores it as the migrate role again."
    log ""
  fi
fi

# The commands that finish a cluster restore: the chart's post-restore Job,
# fed the input this run wrote, run with the release's own configuration. The
# wait is on the first condition the Job records, because it ends either way
# and `kubectl wait` takes one condition; that first one can be an interim
# SuccessCriteriaMet or FailureTarget, so the verdict is read from the pod
# counts, which are final by then, and the log. Addressed by label, like every step of
# the runbook, because the CronJob's name follows the chart's fullname.
cluster_post_restore_notes() {
  local revocations="no revocations were read out of the database it replaced (see the notes below)"
  if [[ "${REVOCATION_OUTCOME:-unavailable}" == exported ]]; then
    revocations="the ${REVOCATIONS_EXPORTED:-0} revocation(s) this run read out of the database it replaced are not re-applied"
  fi
  log "THE POST-RESTORE STEPS HAVE NOT RUN. On Kubernetes they run in the cluster, as the Job the chart"
  log "  renders with the release's own ConfigMap and Secret, because they need the Server's whole"
  log "  configuration: the signing key, API_KEY_SECRET, the external URL and the anchor settings."
  log "  Until it completes, nothing has marked this restore on the chain, nothing has compared the"
  log "  external anchors against the restored database, and ${revocations}."
  if [[ "${MIGRATE_OUTCOME:-pending}" == ok ]]; then
    log "  Keep the api and worker Deployments at 0 and run it now."
  else
    log "  It needs the current schema: keep the api and worker Deployments at 0 and run it once a"
    log "  migration of ${SERVING_VERSION:-this release} has succeeded on the restored database."
  fi
  log ""
  log "  Its input is in ${POST_RESTORE_INPUT:-<not written>}. With NS the release's namespace and REL its name:"
  if [[ "${REVOCATION_OUTCOME:-unavailable}" == exported ]]; then
    # A re-run reads the restored database, which does not hold them.
    log "  (That directory is the only copy of the revocations read before the drop: a re-run of this"
    log "  script reads the restored database, which does not hold them. Use this directory's input.)"
  fi
  log "    PR=\$(kubectl get cronjob -n \"\$NS\" -l \"app.kubernetes.io/instance=\$REL,app.kubernetes.io/component=post-restore\" \\"
  log "      -o jsonpath='{.items[0].metadata.name}')"
  log "    kubectl delete secret -n \"\$NS\" \"\$PR\" --ignore-not-found"
  log "    kubectl create secret generic -n \"\$NS\" \"\$PR\" --from-file=\"${POST_RESTORE_INPUT:-<input directory>}\""
  log "    kubectl create job -n \"\$NS\" --from=cronjob/\"\$PR\" ${POST_RESTORE_JOB:-agledger-post-restore}"
  log "    kubectl wait -n \"\$NS\" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=15m job/${POST_RESTORE_JOB:-agledger-post-restore}"
  log "    kubectl logs -n \"\$NS\" job/${POST_RESTORE_JOB:-agledger-post-restore}"
  log "    kubectl get job -n \"\$NS\" ${POST_RESTORE_JOB:-agledger-post-restore} -o jsonpath='succeeded={.status.succeeded} failed={.status.failed}{\"\\n\"}'"
  log "    kubectl delete secret -n \"\$NS\" \"\$PR\""
  log ""
  log "  The get prints succeeded=1 when the steps ran, and the log says what they found: the"
  log "  revocations re-applied, the marker the next boot turns into a RESTORE_EPOCH entry, and the"
  log "  anchor comparison. A rewind it finds refuses chain writes until acknowledged at"
  log "  POST /v1/admin/vault/rewind/acknowledge. failed=1 means the steps did not run; fix what the"
  log "  log names and create another Job under a new name from the same Secret, which is the same"
  log "  restore. An empty PR means the release renders no post-restore CronJob (postRestore.enabled)."
  log ""
  log "  When the log says the anchor comparison stopped before the end of the bucket, finish it once"
  log "  the Deployments are back up. Restarting the worker walks the bucket at its boot with a longer"
  log "  budget than an API call can hold; then read what it found:"
  log "    kubectl rollout restart -n \"\$NS\" deploy -l \"app.kubernetes.io/instance=\$REL,app.kubernetes.io/component=worker\""
  log "    curl -sS -H 'Authorization: Bearer <platform key>' <AGLEDGER_EXTERNAL_URL>/v1/admin/vault/rewind"
  log ""
}

# What the operator has to know about the database that is now on disk,
# whichever way this run ends.
#
# These sat below the runtime-role gate's `die`, so the one path where they
# matter most printed neither: a restore that stopped at the gate had replaced
# api_keys and possibly lost the audit trigger, and said nothing about either.
# The operator was told to run a grant and bring the stack up, and then met a
# 401 with no explanation.
post_restore_notes() {
  if [[ "${AUDIT_TRIGGER_MISSING}" == "true" ]]; then
    log "One thing did not come back: the audit-chain event trigger 'agledger_block_audit_drop'."
    log "See the WARN above for the single statement that restores it. Your records and the"
    log "signature chain are intact and verify offline; what is missing is the in-band DROP guard"
    log "on the audit tables (layer 2 of the tamper model)."
    log ""
  fi
  # The restore replaced api_keys with the backup's copy, so the credential
  # situation changed underneath the operator and nothing else says so. Two ways
  # to end up locked out of a healthy server holding all your data: a key minted
  # after the backup (including the one a reinstall printed minutes ago) is gone
  # with the table, and every restored key hashes under the API_KEY_SECRET that
  # was in force when it was minted, so a fresh secret invalidates all of them
  # at once.
  log "Credentials now come from the backup, not from this install:"
  log "  - Any key minted after the backup was taken no longer exists. That includes"
  log "    the platform key a reinstall printed before this restore."
  log "  - Restored keys only authenticate if API_KEY_SECRET, or API_KEY_SECRET_PREVIOUS,"
  log "    matches the value that was in force when they were minted. A different secret"
  log "    fails all of them; set the old one as API_KEY_SECRET_PREVIOUS and restart."
  log ""
  if [[ "${CLUSTER_RESTORE:-false}" == true ]]; then
    log "Once the api is back up, check with a key you expect to work:"
    log "  curl -sS -o /dev/null -w '%{http_code}\\n' -H 'Authorization: Bearer <key>' <AGLEDGER_EXTERNAL_URL>/v1/auth/me"
    log ""
    log "If that answers 401, mint a fresh platform key (the chain and every record"
    log "are unaffected; this only issues a new credential):"
    log "  kubectl exec -n \"\$NS\" \"\$(kubectl get deploy -n \"\$NS\" -l \"app.kubernetes.io/instance=\$REL,app.kubernetes.io/component=api\" -o name)\" -- \\"
    log "    env NODE_OPTIONS= /nodejs/bin/node dist/scripts/generate-api-key.js platform 00000000-0000-0000-0000-000000000000 \"recovery platform key\""
    log ""
  else
    log "Check with a key you expect to work:"
    log "  curl -sS -o /dev/null -w '%{http_code}\\n' -H 'Authorization: Bearer <key>' http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/auth/me"
    log ""
    log "If that answers 401, mint a fresh platform key (the chain and every record"
    log "are unaffected; this only issues a new credential):"
    log "  ${COMPOSE[*]} exec -T -e NODE_OPTIONS= agledger-api /nodejs/bin/node \\"
    log "    dist/scripts/generate-api-key.js platform 00000000-0000-0000-0000-000000000000 \"recovery platform key\""
    log ""
  fi
  # On a cluster the revocation replay and the anchor comparison are both the
  # Job's, so these notes are its commands rather than the Compose ones below.
  if [[ "${CLUSTER_RESTORE:-false}" == true ]]; then
    cluster_post_restore_notes
  fi
  # A revocation is a row in the same database, so the restore undid every one
  # made after the backup. The run read them out of the database it replaced
  # and re-applied them; what it could not read, the operator compares by hand.
  local revocation_note="${REVOCATION_OUTCOME:-unavailable}"
  if [[ "${CLUSTER_RESTORE:-false}" == true && "${revocation_note}" == exported ]]; then
    revocation_note=job
  fi
  case "${revocation_note}" in
    job) ;;
    replayed)
      log "Revocations made after the backup were carried across: ${REVOCATION_SUMMARY:-see the post-restore output}."
      log "  A credential created after the backup is not in the restored database, so a revocation"
      log "  of one had nothing to apply to."
      ;;
    exported|failed)
      # The export was saved beside the archives before the drop (or the run
      # stopped there), so the file named here outlives this run's temp
      # directory. A re-run of this script reads revocations out of the
      # RESTORED database, which does not hold them, so it is the only copy.
      REVOCATION_NOTES_PRINTED=true
      if [[ -n "${REVOCATIONS_SAVED:-}" && -s "${REVOCATIONS_SAVED}" ]]; then
        log "REVOCATIONS MADE AFTER THE BACKUP WERE READ (${REVOCATIONS_EXPORTED:-0}) BUT NOT RE-APPLIED: the post-restore"
        log "  step did not complete. Until they are, a key disabled since the backup authenticates again."
        revocations_saved_note "${THIS_PROJECT}-${RESTORE_MARKER_SUFFIX}"
      elif [[ "${REVOCATIONS_EXPORTED:-0}" == 0 ]]; then
        log "The database this restore replaced held no revocations made after the backup, so the post-restore"
        log "  step not completing left none to carry across."
      else
        log "REVOCATIONS MADE AFTER THE BACKUP WERE READ (${REVOCATIONS_EXPORTED}) BUT NOT RE-APPLIED, and no copy of them"
        log "  was kept. List what can authenticate and disable what you had revoked:"
        log "    ${COMPOSE[*]} run --rm --no-deps -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api dist/scripts/post-restore.js --list-active-credentials"
      fi
      ;;
    *)
      # other_database and unproven land here too: a database that is not the
      # one the backup was dumped from holds none of its revocations, and one
      # nothing could compare may not, which is the position of having none
      # to read. The headline says which was established.
      local db_env=""
      [[ "${CLUSTER_RESTORE:-false}" == true ]] && db_env="DATABASE_URL='<runtime-role URL>' "
      case "${revocation_note}" in
        other_database)
          log "THE DATABASE THIS RESTORE REPLACED DID NOT CARRY ON FROM THIS BACKUP'S STATE, so it held no"
          log "  record of revocations made after the backup and none were carried across."
          ;;
        unproven)
          log "NOTHING SHOWED THAT THE DATABASE THIS RESTORE REPLACED IS THE ONE THIS BACKUP WAS DUMPED FROM,"
          log "  so no revocations were read out of it and none were carried across."
          ;;
        *)
          log "REVOCATIONS COULD NOT BE READ OUT OF THE DATABASE THIS RESTORE REPLACED, so none were carried"
          log "  across. The WARN before the drop has the read's own error; a host with no previous database"
          log "  fails that read too."
          ;;
      esac
      [[ -n "${REVOCATION_SOURCE_NOTE:-}" ]] && log "  ${REVOCATION_SOURCE_NOTE}"
      # A re-run after a run that stopped past its drop lands here, since the
      # database it replaced is the one that run left. That run saved what it
      # read beside the archives, and this is the run to replay it under.
      if [[ "${CLUSTER_RESTORE:-false}" != true ]]; then
        local earlier
        for earlier in "$(backup_root)/revocations-${THIS_PROJECT}-"*.ndjson; do
          [[ -s "${earlier}" ]] || continue
          log "  An earlier restore run on this install saved the revocations it read before its drop at"
          log "  ${earlier}. If that run was restoring this archive and stopped after dropping the database,"
          log "  replay them now:"
          log "    ${COMPOSE[*]} run --rm --no-deps -T -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api \\"
          log "      dist/scripts/post-restore.js --marker-id ${THIS_PROJECT}-${RESTORE_MARKER_SUFFIX} --replay-revocations - < ${earlier}"
        done
      fi
      log "  Any credential revoked after the backup authenticates again until you disable it. List what"
      log "  can authenticate:"
      log "    ${db_env}${COMPOSE[*]} run --rm --no-deps -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api dist/scripts/post-restore.js --list-active-credentials"
      log "  and compare it against your own record of revocations (the SIEM stream carries"
      log "  ADMIN_KEY_REVOKED, ACCOUNT_DEACTIVATED and federation.peer_revoked), then disable through"
      log "  PATCH /v1/admin/api-keys/{keyId} with {\"isActive\": false}."
      ;;
  esac
  log ""
  # The restored chain ends where the backup did, and the next write reuses
  # positions the lost history already signed and delivered.
  log "Before taking writes, check the chain and reconcile what left this Server after the backup:"
  if [[ "${CLUSTER_RESTORE:-false}" == true ]]; then
    # vault-verify.sh is a Compose wrapper and needs the release's signing key,
    # which this host does not hold. The post-restore CronJob's pod is the
    # api's, so a Job cut from it with the checker as its command runs with the
    # release's ConfigMap, Secret, extraEnv and volumes, and carries the
    # component label the bundled database's NetworkPolicy admits.
    log "  in the cluster, as a Job cut from the post-restore CronJob (PR, as below) with the checker"
    log "  as its command, so it runs with the release's whole configuration:"
    log "    kubectl get cronjob -n \"\$NS\" \"\$PR\" -o json | jq '{apiVersion: \"batch/v1\", kind: \"Job\","
    log "        metadata: {name: \"agledger-vault-verify\"}, spec: (.spec.jobTemplate.spec"
    log "        | .template.spec.containers[0].command |= (map(select(. != \"--restore-input\" and . != \"/etc/agledger/post-restore\"))"
    log "        | map(if . == \"dist/scripts/post-restore.js\" then \"dist/scripts/verify-vault.js\" else . end)))}' \\"
    log "      | kubectl create -n \"\$NS\" -f -"
    log "    kubectl wait -n \"\$NS\" --for=jsonpath='{.status.conditions[0].status}'=True --timeout=30m job/agledger-vault-verify"
    log "    kubectl logs -n \"\$NS\" job/agledger-vault-verify"
    log "    kubectl delete job -n \"\$NS\" agledger-vault-verify"
  else
    log "  ./scripts/vault-verify.sh"
  fi
  log "  Webhook receivers, the SIEM and federation peers hold events for rows this database no"
  log "  longer has. See 'Backups and point-in-time recovery' in README.md."
  log ""

  # On a cluster the anchor comparison is the Job's, and its log says what it
  # found; the Compose outcomes below describe a step this run did not take.
  [[ "${CLUSTER_RESTORE:-false}" == true ]] && return 0

  case "${POST_RESTORE_OUTCOME}" in
    rewound)
      log "THE EXTERNAL ANCHORS SAY THIS DATABASE IS BEHIND WHERE IT HAS ALREADY BEEN."
      log "  The bucket holds chain positions this database does not, which is what a restore to an"
      log "  earlier backup leaves behind. CHAIN WRITES ARE REFUSED on this Server until an operator"
      log "  acknowledges, so records, completions, verdicts and schema registrations all answer 409"
      log "  with reason CHAIN_REWIND_DETECTED."
      log ""
      log "  Read the evidence, then acknowledge:"
      log "    curl -sS -H 'Authorization: Bearer <platform key>' http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/admin/vault/rewind"
      log "    curl -sS -XPOST -H 'Authorization: Bearer <platform key>' -H 'Content-Type: application/json' \\"
      log "      -d '{\"note\":\"what you reconciled, and with whom\"}' \\"
      log "      http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/admin/vault/rewind/acknowledge"
      log ""
      log "  The acknowledgement writes a RESTORE_EPOCH entry onto the platform-ops chain carrying"
      log "  the anchor evidence and your note, so the two histories stay tellable apart."
      log ""
      ;;
    ok)
      log "The external anchors hold no chain position past this database, so nothing this Server"
      log "  anchored off-box is missing from the restored chain. That covers only what was anchored:"
      log "  entries written after the last checkpoint sweep have no external evidence either way."
      log ""
      ;;
    failed)
      log "The post-restore checks did not complete (the output above says why). Run the bucket-to-database"
      log "  comparison by hand once the stack is up; until it has run, nothing has checked whether"
      log "  the anchors hold positions this database no longer does:"
      log "    curl -sS -XPOST -H 'Authorization: Bearer <platform key>' http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/admin/vault/anchors/reconcile"
      log ""
      ;;
    skipped)
      log "NO EXTERNAL-ANCHOR COMPARISON WAS COMPLETED, so nothing has checked whether this restore"
      log "  lost anything. Anchoring is not configured on this install, the vault signing key is not"
      log "  usable against the restored registry, or the walk stopped on its key cap or its time"
      log "  budget before it reached the end of the bucket. The reason is in the post-restore output"
      log "  above. A key that is not usable cannot judge whether a rewind acknowledged before the"
      log "  backup still counts: fix it first (the output names its gate and the setting), because a"
      log "  reconciliation under it records that rewind open again and refuses chain writes until"
      log "  someone acknowledges it again."
      log ""
      log "  With anchoring configured, finish the comparison once the stack is up. Restarting the"
      log "  worker walks the bucket at its boot with a longer budget than an API call can hold"
      log "  (the daily vault-anchor-verify sweep does the same); then read what it found:"
      log "    cd ${COMPOSE_DIR} && docker compose restart agledger-worker"
      log "    curl -sS -H 'Authorization: Bearer <platform key>' http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/admin/vault/rewind"
      log "  POST /v1/admin/vault/anchors/reconcile answers inside the request deadline, so on a large"
      log "  bucket it reports truncated: true rather than a full comparison."
      log ""
      log "  Without it, reconcile against your own external evidence: the SIEM stream of"
      log "  system_audit_log, delivered webhooks, or a federation peer's slice of the chain."
      log ""
      ;;
    *)
      log "No external-anchor comparison was made on this run."
      log ""
      ;;
  esac
}

# The one line that says whether this run ended on the version the dump came
# from. Both endings print it: the runtime-role gate below stops the run with
# the database already restored, and that is exactly the operator who is about
# to start the stack by hand.
version_outcome_note() {
  case "${VERSION_OUTCOME}" in
    mismatch)
      log "This install is on ${SERVING_VERSION}, NOT the version this backup came from." ;;
    unrecorded)
      log "This install is on ${SERVING_VERSION}; this backup does not record which version it came from." ;;
    *)
      log "This install is on ${SERVING_VERSION}, the version this backup came from." ;;
  esac
}

# --- Runtime Role Gate ---
#
# The restore rebuilt the database, so it also rebuilt everything the runtime
# role's access rests on: a dropped database takes its database-level grants
# with it, and the objects come back from the dump. Asking now, before anything
# is started, is what turns "container is unhealthy, restore.sh exits 1, stack
# down, no reason given" into the report that names the role and the exact
# grant. Same check install.sh and upgrade.sh run, at the same point relative
# to the thing it protects.
#
# External database only: on the bundled path the migration run below
# provisions the runtime role itself (agledger_app's login, CREATE on the
# recreated database, the pg-boss schema that --no-owner restored to the owner).
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  log "Checking runtime role privileges..."
  if ! "${COMPOSE[@]}" run --rm --no-deps -e NODE_OPTIONS= \
      --entrypoint /nodejs/bin/node agledger-api \
      dist/scripts/preflight.js --only=runtime-role,pgboss; then
    echo ""
    log "The role in DATABASE_URL cannot serve the restored database. The report above is the"
    log "diagnosis: a privilege failure names the role and the exact grant to run."
    log ""
    log "Your data is restored and intact — this is about access to it, not about the rows."
    log "The API and Worker are still stopped, so nothing is serving a half-configured database."
    if [[ "${VERSION_PLAN}" == pin ]]; then
      # The version move happens below this gate, so it has not happened. An
      # operator who brings the stack up by hand here lands on the release they
      # are rolling back FROM, which is the whole defect this section exists for.
      log "Run the grants the report names, then re-run THIS script: the move to ${BACKUP_VERSION}"
      log "is applied after this check, so bringing the stack up by hand starts ${SERVING_VERSION}."
      echo ""
      log "This install is still on ${SERVING_VERSION}; this backup came from ${BACKUP_VERSION}."
    elif [[ "${CLUSTER_RESTORE}" == true ]]; then
      # Not a re-run: it would read revocations out of the RESTORED database,
      # which does not hold the ones this run read before the drop, and hand
      # the Job a new input directory without them.
      log "Run the grants the report names, then finish from here rather than re-running this script,"
      log "which would read revocations out of the restored database and lose the ones this run kept:"
      log "  ${COMPOSE[*]} run --rm agledger-migrate"
      log "and then the post-restore Job the notes below name, from this run's input directory."
      echo ""
      version_outcome_note
    elif [[ "${NO_START}" == true ]]; then
      log "Run the grants the report names, then re-run this script with the same archive and flags."
      echo ""
      version_outcome_note
    else
      log "Run the grants the report names, then re-run:"
      log "  ${COMPOSE[*]} up -d --wait"
      echo ""
      version_outcome_note
    fi
    log ""
    if [[ "${CLUSTER_RESTORE}" != true ]]; then
      log "Re-running THIS script is the better path either way: the post-restore step below this gate"
      log "did not run, so this restore has left no marker on the chain and nothing has compared the"
      log "external anchors against the restored database."
      if [[ -n "${REVOCATIONS_SAVED:-}" ]]; then
        log "A re-run does not carry across the revocations this run read; the notes below say how to"
        log "replay them once it has finished."
      fi
      log ""
    fi
    post_restore_notes
    die "Restore stopped at the runtime-role check: the data is restored, the migration did not run, and the Server was not started."
  fi
fi

# --- The version this backup came from: apply ---
#
# The other half of the decision above, after the data is back and after the
# runtime-role gate, so a run that stopped short leaves compose/.env describing
# the install that is actually there. The gate runs the image the install is
# still on, which is the one whose preflight this script knows how to ask.
if [[ "${VERSION_PLAN}" == pin ]]; then
  upsert_env_var AGLEDGER_VERSION "${BACKUP_VERSION}" "${COMPOSE_DIR}/.env"
  if [[ -n "${BACKUP_IMAGE_PIN}" ]]; then
    upsert_env_var AGLEDGER_IMAGE_PIN "${BACKUP_IMAGE_PIN}" "${COMPOSE_DIR}/.env"
  else
    # A pin left over from the release being rolled back names the wrong bytes
    # and beats AGLEDGER_VERSION in every compose file, so the version write
    # alone would change nothing.
    delete_env_var AGLEDGER_IMAGE_PIN "${COMPOSE_DIR}/.env"
  fi
  # And in this process, because compose reads the environment before the file:
  # `load_env` exports any `export KEY=value` line it finds in .env, so on an
  # install written that way the stale value would beat everything just written
  # and the restart would come up on the release being rolled back.
  export AGLEDGER_VERSION="${BACKUP_VERSION}"
  if [[ -n "${BACKUP_IMAGE_PIN}" ]]; then
    export AGLEDGER_IMAGE_PIN="${BACKUP_IMAGE_PIN}"
  else
    unset AGLEDGER_IMAGE_PIN
  fi
  SERVING_VERSION="${BACKUP_VERSION}"
  log "compose/.env now names ${BACKUP_VERSION}."
fi

# --- Post-restore steps ---
#
# Everything that has to happen on the restored database BEFORE the Server takes
# its first request. Add a new step to `post_restore_steps` below; each one runs
# against a database that is back, on a schema that is current, with the API and
# Worker still stopped.
#
# The schema is current because this section migrates first. The stack's own
# ordering (`agledger-api depends_on agledger-migrate`) would get there too, but
# only once the API is already booting, which is too late for a step whose whole
# job is to be in place before the first write.
post_restore_steps() {
  log "Applying migrations before the Server starts, so the steps below run on the current schema..."
  local migrate_rc=0
  "${COMPOSE[@]}" run --rm agledger-migrate || migrate_rc=$?
  # 65 is the migration refusing the restored database as another release
  # line's: an archive with no version record that a 1.x install wrote. No
  # re-run of this release migrates it, so the tail is not worth naming.
  if [[ $migrate_rc -eq 65 ]]; then
    MIGRATE_OUTCOME=refused
    POST_RESTORE_OUTCOME=failed
    log "${SERVING_VERSION} refuses the restored database: another build migrated it (a 1.x release,"
    log "  or a pre-release build; the migration's text above says which). The data is on disk"
    log "  exactly as the archive held it, and no re-run of this release will migrate it, so no"
    log "  Server of this release can start on it. Restore an archive this install's release wrote,"
    log "  or restore this one into the build that wrote it."
    return 0
  fi
  if [[ $migrate_rc -ne 0 ]]; then
    MIGRATE_OUTCOME=failed
    POST_RESTORE_OUTCOME=failed
    log "The migration run failed (exit ${migrate_rc}); the output above says why. The rows are back, on"
    log "  the schema the archive holds, and nothing marked this restore on the chain or compared the"
    log "  external anchors against it, because both need the current schema."
    return 0
  fi
  MIGRATE_OUTCOME=ok

  # On a cluster the steps below run as the chart's post-restore Job, with the
  # release's configuration: run here, with only the database URLs, they would
  # fail at config load, and the closing notes would send the operator after
  # compose commands that cannot help.
  if [[ "${CLUSTER_RESTORE}" == true ]]; then
    POST_RESTORE_OUTCOME=cluster
    log "The schema is current. The steps after it run in the cluster, as the chart's post-restore Job;"
    log "  the closing notes say how."
    return 0
  fi

  # Step 1: mark the restore, and compare the external anchors against the
  # restored database.
  #
  # The marker is written whether or not anchoring is configured: the Server
  # always knows a restore happened, and the next boot turns the marker into one
  # signed RESTORE_EPOCH entry on the platform-ops chain plus its SIEM row, so
  # outside parties can tell the history before this restore from the one after
  # it. The marker alone does NOT stop writes.
  #
  # The anchor comparison is what can prove something was lost. It is run here
  # rather than left to the Server's own boot sweep so that a Server whose
  # anchors hold positions this database does not is already refusing chain
  # writes when it answers its first request.
  local rc=0
  local out="${RESTORE_TMP}/post-restore.log"
  # The exported revocations ride in on stdin, so nothing has to be copied into
  # the container; a run with nothing exported passes no flag and replays none.
  local replay_args=()
  if [[ "${REVOCATION_OUTCOME}" == exported ]]; then
    replay_args=(--replay-revocations -)
  fi
  set +e
  "${COMPOSE[@]}" run --rm --no-deps -T -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api \
    dist/scripts/post-restore.js \
    --marker-id "${THIS_PROJECT}-${RESTORE_MARKER_SUFFIX}" \
    --restored-at "${RESTORE_STARTED_AT}" \
    --archive "$(basename "${TARBALL}")" \
    ${replay_args[@]+"${replay_args[@]}"} < "${REVOCATIONS_FILE}" 2>&1 | tee "${out}"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "${REVOCATION_OUTCOME}" == exported ]]; then
    if grep -q '^Revocations replayed onto the restored database:' "${out}"; then
      REVOCATION_OUTCOME=replayed
      REVOCATION_SUMMARY="$(sed -n 's/^Revocations replayed onto the restored database: \(.*\)\.$/\1/p' "${out}" | tail -1)"
      # Applied, so the copy saved before the drop has done its job.
      if [[ -n "${REVOCATIONS_SAVED:-}" ]]; then
        rm -f "${REVOCATIONS_SAVED}"
        REVOCATIONS_SAVED=""
      fi
    else
      REVOCATION_OUTCOME=failed
    fi
  fi

  # The instance id the RESTORED database carries, written back into .env.
  #
  # `reconcile_env_file` above mints a fresh AGLEDGER_INSTANCE_ID into a .env
  # that has none, which is exactly the .env a rebuilt DR host arrives with.
  # Every external anchor this install ever wrote is under the id in the
  # database, so the database wins and .env follows it. Without this the Server
  # refuses to boot on the disagreement.
  local restored_instance_id
  restored_instance_id="$(sed -n 's/^POST_RESTORE_INSTANCE_ID=//p' "${out}" | tr -d '\r' | tail -1)"
  if [[ -n "${restored_instance_id}" ]]; then
    if [[ "${restored_instance_id}" != "$(get_env_value AGLEDGER_INSTANCE_ID "${COMPOSE_DIR}/.env")" ]]; then
      upsert_env_var AGLEDGER_INSTANCE_ID "${restored_instance_id}" "${COMPOSE_DIR}/.env"
      export AGLEDGER_INSTANCE_ID="${restored_instance_id}"
      log "compose/.env now names the instance id this database carries (${restored_instance_id}); it is"
      log "  the prefix every external anchor this install has written is under."
    fi
  else
    log "WARN: the post-restore step did not report the restored database's instance id. If this host's"
    log "      compose/.env names a different AGLEDGER_INSTANCE_ID than the database does, the Server"
    log "      refuses to boot and names both values."
  fi

  case "${rc}" in
    0) POST_RESTORE_OUTCOME=ok ;;
    3) POST_RESTORE_OUTCOME=rewound ;;
    4) POST_RESTORE_OUTCOME=skipped ;;
    *)
      POST_RESTORE_OUTCOME=failed
      log "WARN: the post-restore step exited ${rc}. See its output above. Your data is restored;"
      log "      what may be missing is the chain's own marker for this restore and the comparison"
      log "      against the external anchors. The Server re-tries both on its next boot."
      ;;
  esac

  # Step 2 goes here. Anything added below becomes the function's return status,
  # so end it the way step 1 does, with an assignment or a `log`.
}

post_restore_steps

# A migration that did not finish ends the run here. Nothing is started, and
# nothing below this point would be true: the database is restored, not
# migrated, and the marker and the anchor comparison did not run. The exit
# status says so, because a caller reading 0 moves on to scaling the Server up.
if [[ "${MIGRATE_OUTCOME}" != ok ]]; then
  echo ""
  log "========================================="
  log "Restore NOT complete: the data is back and the migration did not run to the end."
  version_outcome_note
  log "========================================="
  log ""
  log "Nothing was started. Do not start anything that serves this database (on a cluster, leave"
  log "the api and worker Deployments at 0) until a migration of ${SERVING_VERSION} succeeds on it."
  if [[ "${MIGRATE_OUTCOME}" == failed ]]; then
    log "Fix what the migration reported, then finish from here, with the same environment this run had."
    log "The data is already restored, so nothing needs dropping again:"
    log "  ${COMPOSE[*]} run --rm agledger-migrate"
    if [[ "${CLUSTER_RESTORE}" == true ]]; then
      log "Then run the post-restore Job the notes below name."
    else
      log "  ${COMPOSE[*]} run --rm --no-deps -T -e NODE_OPTIONS= --entrypoint /nodejs/bin/node agledger-api \\"
      log "    dist/scripts/post-restore.js --marker-id ${THIS_PROJECT}-${RESTORE_MARKER_SUFFIX} \\"
      log "    --restored-at ${RESTORE_STARTED_AT} --archive $(basename "${TARBALL}")"
      log "The second marks this restore on the chain and compares the external anchors; the notes below"
      log "say how to carry across the revocations this run read."
    fi
  fi
  log ""
  post_restore_notes
  die "Restore did not finish: the database is restored but not migrated, and the Server was not started."
fi

# --- Restart all services ---

if [[ "${NO_START}" == true ]]; then
  if [[ "${CLUSTER_RESTORE}" == true ]]; then
    log "--no-start: leaving the compose stack down. The database is restored and migrated; keep the"
    log "  api and worker Deployments at 0 until the post-restore Job below has run."
  else
    log "--no-start: leaving the compose stack down. The database is restored and migrated; start"
    log "  whatever serves it."
  fi
  # The .env reconcile above says the containers pick the repairs up "when this
  # run starts them", and this run starts nothing. Only the metrics-token one
  # leaves a container that is already up holding a stale value, so it is the
  # one worth naming here; the rest land whenever the operator does start it.
  if [[ "$MONITORING_ACTIVE" == true ]] && prometheus_metrics_token_stale "${COMPOSE_DIR}/.env"; then
    log "  The bundled Prometheus is still up and holding an older /metrics token than .env names,"
    log "  so it is collecting nothing. Recreate it when you bring the stack back:"
    log "    (cd ${COMPOSE_DIR} && docker compose up -d)"
  fi
else
  log "Restarting all services..."
  # The restore is done by now, and what the operator needs next (the chain
  # check, the anchor evidence, the acknowledgement) is in the closing notes,
  # so a stack that does not come up healthy is reported with them rather
  # than ending the run on compose's one line.
  if ! "${COMPOSE[@]}" up -d --wait; then
    echo ""
    log "========================================="
    log "The data is restored and migrated, and the stack did not come up healthy."
    version_outcome_note
    log "========================================="
    if report_failed_compose_services agledger-api agledger-worker; then
      # The api and worker are up, so compose's own error above names the
      # service that is not; its state is in the listing.
      log "The api and worker are up. The service compose names above is the one that is not:"
      "${COMPOSE[@]}" ps -a || true
      log ""
      post_restore_notes
      die "Restore finished, and a service other than the api and worker is not healthy: see compose's error above."
    fi
    log ""
    log "The api and worker fail their readiness probe while this process may not sign. Its signing key"
    log "state is on /health, which answers while /health/ready does not:"
    log "  curl -sS http://localhost:${AGLEDGER_HOST_PORT:-3001}/health | jq .signingKey"
    log "  unregistered: the log line 'Could not register VAULT_SIGNING_KEY' carries the error, and the"
    log "    process retries on its own. unanchored: set VAULT_SIGNING_KEY_PREVIOUS to the key the restored"
    log "    registry holds (or VAULT_TRUST_ANCHORS) in compose/.env, and restart. That setting belongs in"
    log "    compose/.env before restore.sh runs: without it the post-restore step above did not compare the"
    log "    anchors, and the worker's boot reconciliation, running under a key that is not usable, records"
    log "    any rewind acknowledged before the backup open again, so chain writes stay refused until it is"
    log "    acknowledged again. A detected rewind does not stop a key registering; the acknowledgement"
    log "    below is signed under it once it does."
    log ""
    post_restore_notes
    die "Restore finished, and the api or worker is not healthy: see the reasons above."
  fi
fi

echo ""
log "========================================="
if [[ "${CLUSTER_RESTORE}" == true ]]; then
  log "Data restored and migrated. Not complete until the post-restore Job below has run."
else
  log "Restore complete."
fi
version_outcome_note
log "========================================="
log ""
post_restore_notes
