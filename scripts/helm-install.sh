#!/usr/bin/env bash
# AGLedger Helm Quick-Start — generates secrets and installs in one command.
#
# Usage:
#   curl -fsSL https://agledger.ai/helm-install.sh | bash
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --db postgresql://user:pass@host/db
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --bundled
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --values my-values.yaml
#
# External-database TLS:
#   The image bundles the AWS RDS / Aurora root CA at /etc/ssl/certs/rds-global-bundle.pem.
#   It is auto-applied when an external DB is chosen interactively.
#     --ca-cert <path>   override the cert path (must exist inside the container)
#     --no-ca-cert       skip the cert (only safe for DBs that don't require TLS)
#
# Supply-chain verification:
#   Signatures are checked when cosign is present, and skipped with a warning
#   when it is not. The two levers, in opposite directions:
#     --skip-verify                 skip the check even where cosign exists (dev ONLY)
#     AGLEDGER_REQUIRE_VERIFY=true  refuse to install when it cannot be checked
#   Set AGLEDGER_REQUIRE_VERIFY for production and in CI: it is what makes
#   verification mandatory rather than best-effort.
#
set -euo pipefail

CHART="oci://registry-1.docker.io/agledger/agledger-chart"
RELEASE="agledger"
NAMESPACE="default"
DB_URL=""
BUNDLED=false
EXTRA_VALUES=""
EXTRA_ARGS=""
VERSION=""
CA_CERT=""
# Bundled in the agledger/agledger image at build time. Covers AWS RDS / Aurora.
DEFAULT_RDS_CA="/etc/ssl/certs/rds-global-bundle.pem"

info()  { echo "  [*] $*"; }
fatal() { echo "  [!] $*" >&2; exit 1; }

# The advertised entry point is `curl ... | bash`, where the script's own source
# IS stdin. A bare `read` there consumes the next LINE OF THE SCRIPT as the
# operator's answer, and bash then parses the wreckage: the first prompt below
# used to swallow its own `case` statement and die on `syntax error near
# unexpected token ')'`, which reads like a truncated download rather than a
# script that cannot prompt.
#
# So prompts go to the controlling terminal, and where there is no terminal
# (CI, cron, a piped run with no tty) we take the default the prompt already
# advertises and say so, instead of asking a question nobody can answer.
# Probe by actually opening /dev/tty for reading: it exists inside containers
# and detached runs where `test -r` passes but open() fails with ENXIO.
TTY_IN=""
if (exec 3</dev/tty) 2>/dev/null; then
  TTY_IN=/dev/tty
elif [[ -t 0 ]]; then
  TTY_IN=/dev/stdin
fi

# A backgrounded run (`curl ... | bash &`) has a controlling terminal it is not
# in the foreground group of, so /dev/tty opens and then reading it raises
# SIGTTIN, whose default action STOPS the process: the install would sit at the
# prompt forever with no output explaining why. Ignoring the signal turns that
# read into a plain EIO failure, which falls through to the default below.
trap '' TTIN 2>/dev/null || true

# ask <varname> <prompt> <default> <flag-to-set-it-non-interactively>
ask() {
  local __var="$1" __prompt="$2" __default="$3" __flag="$4" __reply="" __ok=0
  if [[ -n "$TTY_IN" ]]; then
    # Prompt written separately rather than with `read -p` so the read's own
    # stderr can be dropped: the backgrounded case above surfaces there as a
    # raw "read error: 0: Input/output error" immediately before the line that
    # actually explains what happened.
    printf '%s' "$__prompt" >&2
    if read -r __reply <"$TTY_IN" 2>/dev/null; then __ok=1; fi
  fi
  # A nonzero `read` still assigns what it managed to consume, which is a real
  # answer when the operator ended the line with EOF instead of Enter. Only an
  # empty-handed failure is a fallback, and only that is worth narrating.
  if [[ "$__ok" -eq 0 && -z "$__reply" ]]; then
    info "No terminal for input; using the default (${__default:-empty}). Pass ${__flag} to choose."
  fi
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --db)           DB_URL="$2"; shift 2 ;;
    --bundled)      BUNDLED=true; shift ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --release)      RELEASE="$2"; shift 2 ;;
    --values)       EXTRA_VALUES="$2"; shift 2 ;;
    --version)      VERSION="$2"; shift 2 ;;
    --marketplace)  EXTRA_ARGS="$EXTRA_ARGS --set marketplace.productId=$2"; shift 2 ;;
    --ca-cert)      CA_CERT="$2"; shift 2 ;;
    --no-ca-cert)   CA_CERT="none"; shift ;;
    --skip-verify)  export AGLEDGER_SKIP_VERIFY=true; shift ;;
    *)              EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
  esac
done

# Keyless signature verification. The release pipeline signs
# the chart + image via GitHub OIDC -> Fulcio -> public Rekor. This bootstrap is
# advertised as curl|bash, so it MUST verify before it installs/runs anything.
AGLEDGER_SIGNER_IDENTITY_REGEXP='^https://github\.com/agledger-ai/agledger-api/\.github/workflows/.+@refs/tags/v.+$'
AGLEDGER_SIGNER_OIDC_ISSUER='https://token.actions.githubusercontent.com'

# verify_ref <oci-ref> <human-label> — fail-closed when cosign is present and
# verification fails; warn + proceed when cosign is absent (OOTB-first), unless
# AGLEDGER_REQUIRE_VERIFY=true.
verify_ref() {
  local ref="$1" label="$2"
  if [[ "${AGLEDGER_SKIP_VERIFY:-false}" == "true" ]]; then
    info "AGLEDGER_SKIP_VERIFY=true — skipping ${label} verification (dev/local ONLY)."
    return 0
  fi
  if ! command -v cosign >/dev/null 2>&1; then
    [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]] \
      && fatal "cosign not installed and AGLEDGER_REQUIRE_VERIFY=true. Install cosign 3.x: https://docs.sigstore.dev/system_config/installation/"
    info "cosign not installed — cannot verify ${label}. Install cosign 3.x for supply-chain verification. Proceeding UNVERIFIED."
    return 0
  fi
  if cosign verify \
       --certificate-identity-regexp "$AGLEDGER_SIGNER_IDENTITY_REGEXP" \
       --certificate-oidc-issuer "$AGLEDGER_SIGNER_OIDC_ISSUER" \
       "$ref" >/dev/null 2>&1; then
    info "Verified ${label} signature (keyless, public Rekor): ${ref}"
    return 0
  fi
  fatal "Signature verification FAILED for ${label} (${ref}). Refusing to proceed. Override for dev ONLY: --skip-verify"
}

# Resolve a public Docker Hub tag -> immutable digest (sha256:...), or empty.
# Lets us verify + run the exact bytes by digest instead of a mutable tag.
resolve_dockerhub_digest() {
  local repo="$1" tag="$2" token
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
  token=$(curl -fsSL --max-time 10 \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null \
    | jq -r '.token // empty' 2>/dev/null)
  [[ -n "$token" ]] || return 0
  curl -fsSL --max-time 10 -o /dev/null -D - \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" 2>/dev/null \
    | awk 'tolower($1)=="docker-content-digest:"{print $2}' | tr -d '\r' || true
}

echo ""
echo "  AGLedger Helm Quick-Start"
echo "  ========================"
echo ""

# Check prerequisites
command -v helm >/dev/null 2>&1 || fatal "helm is required. Install: https://helm.sh/docs/intro/install/"
command -v kubectl >/dev/null 2>&1 || fatal "kubectl is required."
kubectl cluster-info >/dev/null 2>&1 || fatal "No Kubernetes cluster available. Check kubectl config."

# OpenShift admits pods with MustRunAsRange, so the chart's stock uid/gid
# request (65532) is rejected by the default restricted-v2 SCC. Detecting it
# here is the difference between a working install and an admission error
# naming a uid the operator never chose.
#
# Asks the cluster, not the workstation: `oc` on the PATH says nothing about
# which context kubectl is pointed at.
IS_OPENSHIFT=false
if kubectl api-versions 2>/dev/null | grep -q '^security\.openshift\.io/'; then
  IS_OPENSHIFT=true
fi

# Resolve a concrete version so the chart + image can be pinned AND verified.
# cosign needs a concrete tag, not a floating "latest".
if [[ -z "$VERSION" ]] && [[ "${AGLEDGER_SKIP_VERIFY:-false}" != "true" ]]; then
  if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # `|| true`: under `set -euo pipefail` a no-match `grep` would otherwise abort
    # the whole script instead of falling through to the graceful message below.
    #
    # Field-wise numeric sort, not `sort -V`: -V is GNU-only and BSD sort
    # (macOS) errors out, which would silently resolve no version at all. The
    # grep ahead of it leaves only bare numeric triples, where the two
    # orderings agree (1.9.0 < 1.10.0 included).
    VERSION=$(curl -fsSL --max-time 10 \
      "https://hub.docker.com/v2/repositories/agledger/agledger-chart/tags?page_size=100" 2>/dev/null \
      | jq -r '.results[].name' 2>/dev/null \
      | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)
    [[ -n "$VERSION" ]] && info "Resolved latest chart version: $VERSION"
  fi
  [[ -z "$VERSION" ]] && info "Could not resolve a concrete version to verify — pass --version X.Y.Z to enable verification."
fi

# Verify the chart and the image before installing / running them.
# Resolve the image to a digest and verify THAT (not the mutable tag), so the
# keygen pod below runs exactly the bytes we verified — no verify-then-repoint gap.
IMG_REF="agledger/agledger${VERSION:+:$VERSION}"
if [[ -n "$VERSION" ]]; then
  verify_ref "registry-1.docker.io/agledger/agledger-chart:$VERSION" "Helm chart"
  IMG_DIGEST=$(resolve_dockerhub_digest agledger/agledger "$VERSION")
  if [[ "${IMG_DIGEST:-}" == sha256:* ]]; then
    verify_ref "registry-1.docker.io/agledger/agledger@$IMG_DIGEST" "container image"
    IMG_REF="agledger/agledger@$IMG_DIGEST"
  else
    verify_ref "registry-1.docker.io/agledger/agledger:$VERSION" "container image"
  fi
elif [[ "${AGLEDGER_SKIP_VERIFY:-false}" != "true" ]] && [[ "${AGLEDGER_REQUIRE_VERIFY:-false}" == "true" ]]; then
  fatal "AGLEDGER_REQUIRE_VERIFY=true but no concrete version to verify. Pass --version X.Y.Z."
fi

# Determine database mode
if [[ -n "$DB_URL" ]]; then
  info "Using external database"
elif [[ "$BUNDLED" == "true" ]]; then
  info "Using bundled PostgreSQL (dev/test only)"
else
  echo ""
  echo "  Choose a database option:"
  echo "    1) Bundled PostgreSQL (free, dev/test)"
  echo "    2) External database (Aurora, RDS, Cloud SQL)"
  echo ""
  ask db_choice "  Option [1]: " 1 "--bundled or --db <url>"
  # shellcheck disable=SC2154  # assigned by `ask` via printf -v
  case "$db_choice" in
    1) BUNDLED=true; info "Using bundled PostgreSQL" ;;
    2) ask DB_URL "  DATABASE_URL: " "" "--db <url>"
       [[ -n "$DB_URL" ]] || fatal "DATABASE_URL is required for external database"
       if [[ -z "$CA_CERT" ]]; then
         echo ""
         echo "  Database TLS root CA?"
         echo "    Press Enter to use the bundled AWS RDS / Aurora cert (${DEFAULT_RDS_CA})"
         echo "    Type a path inside the container for a custom CA"
         echo "    Type 'none' to skip (most managed Postgres providers require a CA)"
         ask CA_CERT "  CA cert [${DEFAULT_RDS_CA}]: " "$DEFAULT_RDS_CA" "--ca-cert <path> or --no-ca-cert"
       fi
       ;;
    *) fatal "Invalid option" ;;
  esac
fi

# Generate vault signing key using the AGLedger container.
# AGLEDGER_SIGNING_ALGORITHM: ed25519 (default) or es256. es256 is for
# FIPS-mode clusters, whose providers cannot compute Ed25519; it also sets the
# AGLEDGER_ALLOW_NON_DEFAULT_SIGNING_ALG acknowledgment via extraEnv (chain
# consumers need @agledger/verify >= 1.4.0, the release that resolves a
# @agledger/verify-core carrying ES256 under every install shape; core is where
# the support lives).
SIGNING_ALGORITHM="${AGLEDGER_SIGNING_ALGORITHM:-ed25519}"
case "$SIGNING_ALGORITHM" in
  ed25519|es256) ;;
  *) fatal "AGLEDGER_SIGNING_ALGORITHM must be ed25519 or es256, got: ${SIGNING_ALGORITHM}" ;;
esac
# Whether the operator named this value themselves in their own arguments.
#
# `--set-file` below is not "a --set that reads from a file": helm merges ALL
# FileValues AFTER all Values (MergeValues, pkg/cli/values/options.go),
# whatever order the flags appear in, so it beats an operator's own
# `--set secrets.vaultSigningKey=...` even though EXTRA_ARGS is appended after
# it. Their value winning is exactly what this script's own keygen-failure
# message and the chart's secret.yaml guard both tell them to rely on, so when
# they name one we stay out of the way entirely: no keygen pod, no flag of
# ours, and no "save this key" line naming a key they never asked for.
#
# Only their `--set*` forms are checked, not a values file: `--set` already
# beat `-f` before this change, so values-file behaviour is unchanged and there
# is nothing here to restore. The two key paths are specific enough that the
# substring collisions `operator_set_openshift` guards against do not apply.
operator_named() {
  [[ "$EXTRA_ARGS" == *"$1"* ]]
}

VAULT_KEY=""
if operator_named secrets.vaultSigningKey; then
  info "Using the vault signing key from your own --set; not generating one."
else
  info "Generating ${SIGNING_ALGORITHM} vault signing key..."
  # POSIX sed to read the key, not `grep -oP`: PCRE lookbehind is GNU-only and
  # BSD grep (macOS) rejects -P outright. This script is piped straight from
  # curl to bash, so it stands alone and cannot use lib-compose's helper.
  # `--attach`, never `-it`. Under `curl ... | bash` the script's source is stdin,
  # and `-i` hands that pipe to the pod, which drains the rest of the script.
  # `--attach` streams the pod's output and waits for it to exit (what `--rm`
  # needs) without claiming stdin; `</dev/null` closes the door behind it.
  VAULT_KEY=$(kubectl run agledger-keygen --rm --attach --restart=Never \
    --image="$IMG_REF" \
    --command -- /nodejs/bin/node dist/scripts/generate-signing-key.js --algorithm "$SIGNING_ALGORITHM" 2>/dev/null </dev/null \
    | sed -n 's/^VAULT_SIGNING_KEY=\([^[:space:]][^[:space:]]*\).*/\1/p' | head -1 || true)

  if [[ -z "$VAULT_KEY" ]]; then
    # Fallback: generate locally with openssl if available.
    #
    # `openssl base64 -A` for the single-line encode, NOT `base64 -w0 || base64`.
    # -w0 is GNU-only, and that fallback is a trap in this script specifically:
    # `A | B || C` groups as `(A|B) || C`, so on macOS the bare `base64` runs with
    # the SCRIPT'S stdin, which under `curl ... | bash` is the rest of the script.
    # It swallows the remainder and the run dies silently, having already created
    # the keygen pod. openssl is guaranteed here (it is this branch's condition)
    # and -A is portable.
    if command -v openssl >/dev/null 2>&1; then
      info "Generating key locally with openssl..."
      if [[ "$SIGNING_ALGORITHM" == "es256" ]]; then
        VAULT_KEY=$(openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -outform DER 2>/dev/null | openssl base64 -A 2>/dev/null)
      else
        VAULT_KEY=$(openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -outform DER 2>/dev/null | openssl base64 -A 2>/dev/null)
      fi
    fi
  fi

  # --set-file, not --set: an argument is world-readable through `ps` and
  # /proc for the length of the install, and this is the private key every
  # record on the chain is signed with.
  [[ -n "$VAULT_KEY" ]] || fatal "Could not generate vault signing key. Generate one and pass it as a file:
    umask 077
    openssl genpkey -algorithm ed25519 | openssl pkey -outform DER | openssl base64 -A > vault-signing-key
    ${0##*/} --set-file secrets.vaultSigningKey=./vault-signing-key ..."

  info "Vault signing key generated"
fi

# Secret values go to helm through files, not the command line. `eval` puts
# the whole command in the helm process's argv, where `ps` shows it to every
# other user on the box for the length of the install: the vault signing key
# is the private key every record is signed with, and an external DB URL
# carries its password.
#
# `--set-file` and not a `-f` values file: it keeps the same standing relative
# to an operator's `-f` that `--set` had, so values-file behaviour does not
# change. It does NOT keep the same standing relative to their `--set`, which is
# what `operator_named` above exists to handle. It also sidesteps `--set` value
# parsing, which splits on commas: a database password containing one used to be
# truncated silently.
SECRET_DIR=$(mktemp -d)
trap 'rm -rf "$SECRET_DIR"' EXIT
chmod 700 "$SECRET_DIR"
# mktemp honours TMPDIR, and the path ends up inside a string this script runs
# through `eval`. A quote or a space would re-split it there, and a comma
# cannot be quoted around at all: helm's own --set-file parser splits its
# argument on commas. Refuse with the cause named rather than emit
# "unexpected arguments" from helm.
case "$SECRET_DIR" in
  *[,\'\"[:space:]]*) fatal "TMPDIR path contains a space, quote or comma (${SECRET_DIR}); helm cannot read a secret from it. Set TMPDIR to a simple path and re-run." ;;
esac
if [[ -n "$VAULT_KEY" ]]; then
  # No trailing newline: --set-file uses the file's bytes verbatim as the value.
  printf '%s' "$VAULT_KEY" > "${SECRET_DIR}/vault-signing-key"
  chmod 600 "${SECRET_DIR}/vault-signing-key"
fi

# Build helm install command
HELM_CMD="helm install $RELEASE $CHART"
HELM_CMD="$HELM_CMD --namespace $NAMESPACE --create-namespace"
if [[ -n "$VAULT_KEY" ]]; then
  HELM_CMD="$HELM_CMD --set-file 'secrets.vaultSigningKey=${SECRET_DIR}/vault-signing-key'"
fi
if [[ "$SIGNING_ALGORITHM" == "es256" ]]; then
  # Dedicated chart value; never claim an extraEnv index an operator's own
  # values file or --set could collide with.
  HELM_CMD="$HELM_CMD --set config.allowNonDefaultSigningAlg=true"
fi
# True when the operator has already expressed an openshift.enabled preference,
# in any of the three ways they can reach the chart from here.
#
# Matches `openshift.enabled` rather than a bare `openshift`, because
# EXTRA_ARGS is the catch-all for unrecognized arguments and an OpenShift
# install carries the string in ordinary values: a Route hostname is
# `*.openshiftapps.com` on ROSA, and an internal registry mirror is
# `image-registry.openshift-image-registry.svc`. A bare substring match made
# the most likely OpenShift command the one that silently skipped the flag.
operator_set_openshift() {
  [[ "$EXTRA_ARGS" == *openshift.enabled* ]] && return 0
  # Values files reach us two ways: the script's own --values, and any values
  # flag that fell through to EXTRA_ARGS. Only --set beats a values file on
  # Helm precedence, so overriding one the operator wrote is the case actually
  # worth guarding.
  #
  # Helm accepts six spellings of the values flag and all six render, so all
  # six have to be recognised here. The attached forms
  # (--values=F, -f=F, -fF) arrive as a SINGLE token, so a lookahead on the
  # previous token never sees a filename: the guard fell through and appended
  # --set openshift.enabled=true, beating the explicit `false` the operator
  # wrote in the file.
  local candidate prev="" file
  for candidate in "$EXTRA_VALUES" $EXTRA_ARGS; do
    file=""
    case "$candidate" in
      --values=*) file="${candidate#--values=}" ;;
      -f=*)       file="${candidate#-f=}" ;;
      -f?*)       file="${candidate#-f}" ;;
      *)
        # Detached forms: `-f FILE`, `--values FILE`, and the script's own
        # --values, which is already a bare filename.
        if [[ "$prev" == "-f" || "$prev" == "--values" || "$candidate" == "$EXTRA_VALUES" ]]; then
          file="$candidate"
        fi
        ;;
    esac
    prev="$candidate"
    # --values is a pflag StringSlice, so helm also accepts a comma list under
    # any of the six spellings and reads every element. Check each one.
    if [[ -n "$file" ]]; then
      local part
      local IFS=,
      for part in $file; do
        [[ -n "$part" ]] \
          && grep -q '^[[:space:]]*openshift:' "$part" 2>/dev/null \
          && return 0
      done
    fi
  done
  return 1
}

if [[ "$IS_OPENSHIFT" == true ]]; then
  if operator_set_openshift; then
    info "OpenShift detected; leaving openshift.enabled to your own configuration."
  else
    HELM_CMD="$HELM_CMD --set openshift.enabled=true"
    info "OpenShift detected (security.openshift.io API group present)."
    info "Setting openshift.enabled=true so the SCC assigns the uid instead of the chart"
    info "requesting 65532, which restricted-v2 refuses. Container hardening is unchanged."
  fi
fi

[[ -n "$VERSION" ]] && HELM_CMD="$HELM_CMD --version $VERSION"

if [[ "$BUNDLED" == "true" ]]; then
  HELM_CMD="$HELM_CMD --set postgres.bundled.enabled=true"
elif [[ -n "$DB_URL" ]]; then
  if operator_named database.externalUrl; then
    info "Using the database URL from your own --set; ignoring --db."
  else
    printf '%s' "$DB_URL" > "${SECRET_DIR}/database-url"
    chmod 600 "${SECRET_DIR}/database-url"
    HELM_CMD="$HELM_CMD --set-file 'database.externalUrl=${SECRET_DIR}/database-url'"
  fi
  if [[ -n "$CA_CERT" && "$CA_CERT" != "none" ]]; then
    HELM_CMD="$HELM_CMD --set config.nodeExtraCaCerts=$CA_CERT"
    info "Using TLS CA cert: $CA_CERT"
  fi
fi

[[ -n "$EXTRA_VALUES" ]] && HELM_CMD="$HELM_CMD -f $EXTRA_VALUES"
HELM_CMD="$HELM_CMD $EXTRA_ARGS"

# `helm install` reports a failed hook as a single line naming the Job, and it
# never reads that Job's log. On the runtime-role gate the log IS the diagnosis
# (the role it connected as, the privilege that is missing, and the GRANT that
# supplies it), so print it here, in the same output as the failure, rather than
# leaving the operator to work out that a failed install left a Job behind worth
# looking at.
#
# Speaks only about a gate run THIS invocation started. Every other install
# failure falls through to helm's own message, which already says what it was.

# Identity of the gate Job that already exists, read before helm runs.
#
# The chart keeps a failed gate Job for 24h on purpose, so one is often still
# lying around from an earlier attempt. Without this, a re-run that helm
# refuses outright ("cannot re-use a name that is still in use") would find the
# old Job, and the operator would be told the database role cannot serve, under
# a report naming grants they have already applied, while helm's actual message
# scrolled off the top. `before-hook-creation` deletes and recreates the Job
# whenever the hook really runs, so a changed uid is exactly "this run got that
# far".
preflight_job_uid() {
  kubectl get job --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=preflight" \
      -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null || true
}

report_preflight() {
  local uid succeeded failed job pod
  uid="$(preflight_job_uid)"
  if [[ -z "$uid" || "$uid" == "$PREFLIGHT_UID_BEFORE" ]]; then return 0; fi

  job="$(kubectl get job --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=preflight" \
      -o name 2>/dev/null | head -1 || true)"
  if [[ -z "$job" ]]; then return 0; fi
  succeeded="$(kubectl get "$job" --namespace "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  if [[ "$succeeded" == "1" ]]; then return 0; fi
  failed="$(kubectl get "$job" --namespace "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || true)"

  # The newest pod, by name, rather than `kubectl logs <job>`. The Job retries
  # once, so there can be two, and asked for the Job kubectl prints "Found 2
  # pods, using ..." into the middle of the report and then picks one for
  # itself. Sorting takes the last attempt deliberately.
  pod="$(kubectl get pod --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=preflight" \
      --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"

  echo "" >&2
  if [[ -n "$failed" && "$failed" != "0" ]]; then
    # What ran is preflight, and a privilege failure is only its most likely
    # verdict: it also reports a database it cannot reach and a PostgreSQL too
    # old to run on. Let the report say which; do not put a diagnosis in the
    # header that the exit status does not establish.
    echo "  The database check that runs before anything serves did not pass. Its report:" >&2
  else
    echo "  The database check that runs before anything serves did not finish." >&2
    echo "  What it printed before it stopped:" >&2
  fi
  echo "" >&2
  # --tail=-1 because a selector-resolved read defaults to the last 10 lines,
  # and the half that gets truncated is the remedy.
  kubectl logs "${pod:-$job}" --namespace "$NAMESPACE" --tail=-1 2>&1 | sed 's/^/  /' >&2 || true
  echo "" >&2
  echo "  Migrations are applied and no workload was created, so fixing this costs" >&2
  echo "  nothing but a re-run. Apply what the report asks for, then run this" >&2
  echo "  installer again. A failed release keeps its name, so if" >&2
  echo "  \`helm list --namespace $NAMESPACE\` still shows it, clear it first:" >&2
  echo "    helm uninstall $RELEASE --namespace $NAMESPACE" >&2
}

info "Installing AGLedger..."
echo ""
PREFLIGHT_UID_BEFORE="$(preflight_job_uid)"
if ! eval "$HELM_CMD"; then
  report_preflight
  fatal "Install failed. See the error above."
fi

echo ""
info "AGLedger installed. Waiting for pods..."

# Resource names come from the chart's fullname template, which is
# "<release>-<chart name>" and the chart is named agledger-chart: a name built
# here from the release alone never resolves, and a fullnameOverride would
# defeat any construction anyway. Ask the cluster instead. Every chart resource
# carries the standard instance + component labels, so this holds through a
# rename of either.
API_SELECTOR="app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=api"
API_DEPLOY="$(kubectl get deployment --namespace "$NAMESPACE" -l "$API_SELECTOR" -o name 2>/dev/null | head -1)"
API_SVC="$(kubectl get service --namespace "$NAMESPACE" -l "$API_SELECTOR" -o name 2>/dev/null | head -1)"

if [[ -z "$API_DEPLOY" ]]; then
  fatal "helm reported success, but no deployment in namespace '$NAMESPACE' carries the labels $API_SELECTOR. Check: helm status $RELEASE -n $NAMESPACE && kubectl get all -n $NAMESPACE"
fi

# Don't swallow the rollout status: a crashlooping image would
# otherwise pass through silently and the script prints "Next steps:" as if
# the install succeeded. Surface the real exit so the customer sees the bad
# install before they try to use it.
if ! kubectl rollout status "$API_DEPLOY" --namespace "$NAMESPACE" --timeout=120s; then
  fatal "Pod did not become ready within 120s. Check: kubectl logs $API_DEPLOY -n $NAMESPACE --previous"
fi

echo ""
echo "  Next steps:"
echo "    1. Create platform API key:"
echo "       kubectl exec $API_DEPLOY -n $NAMESPACE -- /nodejs/bin/node dist/scripts/init.js --non-interactive"
echo ""
echo "    2. Port-forward to access API:"
echo "       kubectl port-forward ${API_SVC:-svc/<name from: kubectl get svc -n $NAMESPACE>} -n $NAMESPACE 3001:80"
echo "       curl http://localhost:3001/health"
echo ""
echo "    3. View license status:"
echo "       curl -H 'Authorization: Bearer <platform-key>' http://localhost:3001/v1/admin/license"
echo ""
if [[ -n "$VAULT_KEY" ]]; then
  echo "    Vault signing key (save this for backup/rotation):"
  echo "       $VAULT_KEY"
  echo ""
fi
echo "    Documentation: https://agledger.ai/docs"
echo "    Upgrade to Enterprise: https://agledger.ai/pricing"
echo ""
