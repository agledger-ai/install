#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Restore Script
# =============================================================================
# Restores PostgreSQL data from a backup tarball.
# Works with both bundled PostgreSQL and external databases (Aurora, RDS, etc.).
#
# Usage: ./scripts/restore.sh backup/backup-2026-03-14-120000.tar.gz
#        ./scripts/restore.sh --non-interactive backup/backup-2026-03-14-120000.tar.gz
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib-compose.sh
source "${SCRIPT_DIR}/lib-compose.sh"

NON_INTERACTIVE=false
FORCE=false

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1"; }
die() { log "ERROR: $1"; exit 1; }

# Parse arguments
TARBALL=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --force) FORCE=true; shift ;;
    -*) die "Unknown option: $1" ;;
    *) TARBALL="$1"; shift ;;
  esac
done

[[ -n "${TARBALL}" ]] || die "Usage: $0 [--non-interactive] [--force] <backup-tarball>"
[[ -f "${TARBALL}" ]] || die "Backup file not found: ${TARBALL}"

load_env
detect_db_mode
build_compose_cmd

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
trap 'rm -rf "${RESTORE_TMP}"' EXIT

log "Extracting backup to ${RESTORE_TMP}..."
tar -xzf "${TARBALL}" -C "${RESTORE_TMP}"

# Find the extracted directory (timestamp-named)
RESTORE_DIR=$(find "${RESTORE_TMP}" -mindepth 1 -maxdepth 1 -type d | head -1)
[[ -d "${RESTORE_DIR}" ]] || die "No directory found in backup tarball."
[[ -f "${RESTORE_DIR}/db.dump" ]] || die "db.dump not found in backup."

# Read the dump before touching the database. Everything below this line stops
# the stack and drops the database; a dump that pg_restore refuses discovered
# after that point leaves the operator with neither a running Server nor their
# data. backup.sh checks the same magic when it writes the file, so this catches
# a backup taken by an older release, or one damaged in storage or transit.
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
  die "Nothing was stopped and nothing was dropped. Your install is serving exactly as it was."
fi

# --- Is this database ours to drop? ---
#
# Asked here, above the stop, for the same reason the dump is read here: every
# way this can refuse leaves the operator with a Server that never went down.
# Below this line the API and Worker are stopped, and "nothing was changed" is
# no longer a true thing to say.
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
    die "Nothing was stopped and nothing was dropped. Fix the connection and re-run."
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
      die "Nothing was stopped and nothing was dropped. Fix the connection and re-run."
    fi

    if [[ "${TARGET_SHAPE}" == "other" ]]; then
      if [[ "${FORCE}" == "true" ]]; then
        log "WARN: --force — \"${TARGET_DB}\" on ${PGHOST} holds tables that are not this install's."
        log "      Dropping it anyway, as asked. This cannot be undone."
      else
        log "Database \"${TARGET_DB}\" on ${PGHOST} holds tables but no public.records, so it does"
        log "not look like an AGLedger database. Restoring drops it and everything in it."
        log "If that is genuinely the target, re-run with --force."
        die "Nothing was stopped and nothing was dropped."
      fi
    fi
  fi
fi

# --- Can the restoring role rebuild the schema? ---
#
# The dump carries `agledger_block_audit_drop`, the sql_drop event trigger that
# is layer 1 of the tamper model, and CREATE EVENT TRIGGER is superuser-only.
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
    die "Nothing was stopped and nothing was dropped. Grant the privilege and re-run."
    ;;
  *)
    # Could not ask. That is not the same answer as "no", and it is not grounds
    # to drop the database on a guess either: this is the connection a failover
    # just reset.
    log "Could not determine whether \"${PGUSER:-?}\" can create the audit-chain event trigger."
    [[ -s "${PRIV_ERR}" ]] && while IFS= read -r priv_line; do log "  ${priv_line}"; done < "${PRIV_ERR}"
    die "Nothing was stopped and nothing was dropped. Fix the connection and re-run."
    ;;
  esac
fi

# --- Stop application services ---

log "Stopping application services..."
"${COMPOSE[@]}" stop agledger-api agledger-worker 2>/dev/null || true
"${COMPOSE[@]}" rm -f agledger-migrate 2>/dev/null || true

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
  log "Ensuring postgres is running..."
  "${COMPOSE[@]}" up -d postgres

  WAIT=0
  while [[ ${WAIT} -lt 30 ]]; do
    if "${COMPOSE[@]}" exec -T postgres pg_isready -U "${POSTGRES_USER}" &>/dev/null; then
      break
    fi
    sleep 1
    WAIT=$((WAIT + 1))
  done
  [[ ${WAIT} -lt 30 ]] || die "PostgreSQL did not become ready in 30 seconds."

  "${COMPOSE[@]}" exec -T postgres psql -U "${POSTGRES_USER}" -d postgres -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${POSTGRES_DB}' AND pid <> pg_backend_pid();
  " >/dev/null 2>&1 || true

  "${COMPOSE[@]}" exec -T postgres dropdb -U "${POSTGRES_USER}" --if-exists "${POSTGRES_DB}"
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
  log "      audit_vault, every monthly audit_vault_* partition, org_admin_reads,"
  log "      org_admin_reads_checkpoints, org_admin_read_sequences,"
  log "      org_admin_read_export_manifests and vault_signing_keys."
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
    log "      pg_restore ran as the migrate role, so it owns pgboss now, and the Server"
    log "      cannot tune autovacuum on its own job partitions. Your data is fine; the"
    log "      job tables will just vacuum on the server defaults instead of the aggressive"
    log "      settings the product picks for them."
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
# External database only: the bundled path runs one role that owns everything
# it touches, and an owner carries every privilege by ownership.
if [[ "${USES_BUNDLED_PG}" == "false" ]]; then
  log "Checking runtime role privileges..."
  if ! "${COMPOSE[@]}" run --rm --no-deps \
      --entrypoint /nodejs/bin/node agledger-api \
      dist/scripts/preflight.js --only=runtime-role,pgboss; then
    echo ""
    log "The role in DATABASE_URL cannot serve the restored database. The report above is the"
    log "diagnosis: a privilege failure names the role and the exact grant to run."
    log ""
    log "Your data is restored and intact — this is about access to it, not about the rows."
    log "The API and Worker are still stopped, so nothing is serving a half-configured database."
    log "Run the grants the report names, then re-run:"
    log "  ${COMPOSE[*]} up -d --wait"
    die "Restore finished; the Server was not started."
  fi
fi

# --- Restart all services ---

log "Restarting all services..."
"${COMPOSE[@]}" up -d --wait

echo ""
log "========================================="
log "Restore complete."
log "========================================="
log ""
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
log "  - Restored keys only authenticate if API_KEY_SECRET matches the value that"
log "    was in force when they were minted. A different secret fails all of them."
log ""
log "Check with a key you expect to work:"
log "  curl -sS -o /dev/null -w '%{http_code}\\n' -H 'Authorization: Bearer <key>' http://localhost:${AGLEDGER_HOST_PORT:-3001}/v1/auth/me"
log ""
log "If that answers 401, mint a fresh platform key (the chain and every record"
log "are unaffected; this only issues a new credential):"
log "  ${COMPOSE[*]} exec agledger-api /nodejs/bin/node dist/scripts/init.js --non-interactive"
