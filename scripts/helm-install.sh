#!/usr/bin/env bash
# AGLedger Helm Quick-Start — generates secrets and installs in one command.
#
# Re-running it against a release that already exists reconciles that release in
# place (`helm upgrade --install`) rather than refusing the name, so fixing a
# value costs a re-run and not an uninstall. On that path it generates no key,
# prompts for nothing, and changes only what the arguments of THIS run name.
#
# Usage:
#   curl -fsSL https://agledger.ai/helm-install.sh | bash
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --db postgresql://user:pass@host/db
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --bundled
#   curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --values my-values.yaml
#
# External-database TLS:
#   The image bundles the AWS RDS / Aurora root CA at /etc/ssl/certs/rds-global-bundle.pem.
#   It is applied by default whenever this run names an external database,
#   whether chosen interactively or passed with --db on the command line.
#     --ca-cert <path>   override the cert path (must exist inside the container)
#     --no-ca-cert       skip the cert (only safe for DBs that don't require TLS)
#   Either flag applies on a reconcile exactly as it does on a first install.
#   Without one, a release that already carries a CA of its own keeps it.
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
# An ARRAY, not a string. Pass-through arguments are advertised (`--set`, `-f`),
# and a string concatenation of them has to be re-split by the shell to become
# argv again: `--set config.orgName=Acme Corp` splits into two arguments, and a
# value carrying a quote or a `$(...)` is re-parsed as shell rather than passed
# on. Every consumer below iterates the array; nothing rebuilds the string.
EXTRA_ARGS=()
VERSION=""
CA_CERT=""
EXTERNAL_URL=""
# Bundled in the agledger/agledger image at build time. Covers AWS RDS / Aurora.
DEFAULT_RDS_CA="/etc/ssl/certs/rds-global-bundle.pem"
# The command an operator re-runs this script by, for the two messages that
# print one. Under the advertised `curl ... | bash` entry point there is no
# local file at all ($0 is the shell), so the command IS the pipeline; a run
# from a downloaded copy is re-run by that copy's own path. Printing a bare
# file name would be neither: `helm-install.sh` is not on anyone's PATH, and
# under curl|bash it is not on their disk.
installer_command() {
  case "${1##*/}" in
    bash|-bash|sh|-sh|dash|zsh|ksh) ;;
    *)
      if [[ -f "$1" ]]; then
        case "$1" in
          */*) printf 'bash %s' "$1"; return 0 ;;
          *)   printf 'bash ./%s' "$1"; return 0 ;;
        esac
      fi
      ;;
  esac
  printf 'curl -fsSL https://agledger.ai/helm-install.sh | bash -s --'
}
SELF="$(installer_command "$0")"

info()  { echo "  [*] $*"; }
fatal() { echo "  [!] $*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
  AGLedger Helm Quick-Start

  Usage:
    helm-install.sh [options]
    curl -fsSL https://agledger.ai/helm-install.sh | bash
    curl -fsSL https://agledger.ai/helm-install.sh | bash -s -- --bundled

  Options:
    --db <url>            External PostgreSQL connection string
    --bundled             Use the chart's bundled PostgreSQL
    --external-url <url>  Public URL this Server is reachable at. Signed into
                          every record as the issuer, and permanent.
    --namespace <ns>      Kubernetes namespace (default: default)
    --release <name>      Helm release name (default: agledger)
    --values <file>       Extra values file, passed to helm as -f
    --version <X.Y.Z>     Chart/image version. Required to verify signatures
                          when the version cannot be resolved from Docker Hub.
                          Omitted on an existing release, the run stays on the
                          version that release's own revisions name.
    --marketplace <id>    AWS Marketplace product id
    --ca-cert <path>      Database TLS root CA inside the container
                          (default: /etc/ssl/certs/rds-global-bundle.pem).
                          Applies on a reconcile as it does on a first install.
    --no-ca-cert          Skip the CA cert (only for a DB not requiring TLS).
                          Clears one a release already carries.
    --skip-verify         Skip signature verification (dev ONLY)
    --help, -h            Print this and exit

  Anything else is passed through to `helm upgrade --install` unchanged, so
  `--set key=value` and `-f other-values.yaml` work here. Arguments are kept
  as a list and handed to helm as one, so a value carrying a space or a quote
  reaches it whole.

  Re-running against an existing release reconciles it in place, including a
  release whose first install failed. The values that release already holds
  are carried forward onto the chart's defaults (helm's
  --reset-then-reuse-values); only what this run's arguments name is changed.

  Environment:
    AGLEDGER_REQUIRE_VERIFY=true    refuse to install when signatures cannot
                                    be checked. Set this in production and CI.
    AGLEDGER_SIGNING_ALGORITHM      ed25519 (default) or es256 for FIPS hosts.

  Verify before running (each release publishes both files):
    R=https://github.com/agledger-ai/install/releases/latest/download
    curl -fsSLO $R/helm-install.sh -O $R/helm-install.sh.sha256
    sha256sum -c helm-install.sh.sha256 && bash helm-install.sh

  Docs: https://agledger.ai/docs
USAGE
}

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
    # Before every probe below, because --help that answers "No Kubernetes
    # cluster available" is a script telling the operator to fix their cluster
    # in order to read what its own flags are.
    --help|-h)      usage; exit 0 ;;
    --db)           DB_URL="$2"; shift 2 ;;
    --external-url) EXTERNAL_URL="$2"; shift 2 ;;
    --bundled)      BUNDLED=true; shift ;;
    --namespace)    NAMESPACE="$2"; shift 2 ;;
    --release)      RELEASE="$2"; shift 2 ;;
    --values)       EXTRA_VALUES="$2"; shift 2 ;;
    --version)      VERSION="$2"; shift 2 ;;
    --marketplace)  EXTRA_ARGS+=(--set "marketplace.productId=$2"); shift 2 ;;
    --ca-cert)      CA_CERT="$2"; shift 2 ;;
    --no-ca-cert)   CA_CERT="none"; shift ;;
    --skip-verify)  export AGLEDGER_SKIP_VERIFY=true; shift ;;
    *)              EXTRA_ARGS+=("$1"); shift ;;
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

# Secret values go to helm through files, not the command line: an argument is
# world-readable through `ps` and /proc for the length of the install, and one
# of these is the private key every record on the chain is signed with.
#
# `--set-file` and not a `-f` values file: it keeps the same standing relative
# to an operator's `-f` that `--set` had, so values-file behaviour does not
# change. It does NOT keep the same standing relative to their `--set`, which is
# what `operator_named` above exists to handle. It also sidesteps `--set` value
# parsing, which splits on commas: a database password containing one used to be
# truncated silently.
#
# Created here rather than at the first write because the release-values
# snapshot below lands in it, and that snapshot can carry a database password.
SECRET_DIR=$(mktemp -d)
trap 'rm -rf "$SECRET_DIR"' EXIT
chmod 700 "$SECRET_DIR"
# mktemp honours TMPDIR, and the path ends up inside a `--set-file` argument.
# helm's own strvals parser splits that argument on commas and reads a
# backslash as an escape, so neither can be quoted around. A quote or a space
# is refused with them: a TMPDIR carrying one is not a path this script should
# be building helm arguments out of. Name the cause rather than let helm report
# "unexpected arguments".
case "$SECRET_DIR" in
  *[,\\\'\"[:space:]]*) fatal "TMPDIR path contains a space, quote, comma or backslash (${SECRET_DIR}); helm cannot read a secret from it. Set TMPDIR to a simple path and re-run." ;;
esac

# Does this release already exist? `helm install` refuses a name that is in use,
# so before this the ONLY way to correct a value was `helm uninstall` and a
# fresh install, which on a bundled-PG release means the database too. The
# install is a `helm upgrade --install`, and everything below that would
# generate, prompt for, or overwrite state reads this first.
#
# A FAILED release counts as existing: helm keeps the name, and `helm upgrade`
# is what clears it. That is the common case here, since the release most in
# need of a re-run is the one whose first install did not finish.
RELEASE_EXISTS=false
RELEASE_VALUES="${SECRET_DIR}/release-values.yaml"
: > "$RELEASE_VALUES"
chmod 600 "$RELEASE_VALUES"
if helm status "$RELEASE" --namespace "$NAMESPACE" >/dev/null 2>&1 \
   && ! helm list --namespace "$NAMESPACE" --uninstalled -q 2>/dev/null | grep -qx -- "$RELEASE"; then
  # `helm status` also succeeds for a release left behind by
  # `helm uninstall --keep-history`: the name and the revision history survive,
  # every resource is gone. helm's own `--install` routes THAT to the install
  # path and drops the reuse flag with it, so treating it as existing here would
  # leave the chart with no vault key and no issuer, and a first-install failure
  # to explain it. `helm list --uninstalled` is helm's own name for the state,
  # so this cannot drift from the branch helm will take.
  RELEASE_EXISTS=true
  # The values the operator supplied, and only those. `-o yaml` rather than the
  # default table form, which prefixes a "USER-SUPPLIED VALUES:" header the
  # `declares_*` matchers below would have to know about; without it this is the
  # same YAML shape a values file has and they read it unchanged. It can carry a
  # database password, which is why it lives under SECRET_DIR.
  #
  # A failure here is fatal, not swallowed. Every `release_declares` consumer
  # reads this file, an unreadable one is indistinguishable from a release that
  # declares nothing, and the consequence of that mistake is the issuer prompt
  # defaulting to https://localhost over the permanent issuer of a live chain.
  # Refuse rather than guess.
  if ! helm get values "$RELEASE" --namespace "$NAMESPACE" -o yaml >"$RELEASE_VALUES" 2>/dev/null; then
    fatal "Release '${RELEASE}' exists in namespace '${NAMESPACE}' but its values could not be read, and this run would have to guess what it already holds. The issuer is permanent, so it stops instead of guessing. Check: helm get values ${RELEASE} --namespace ${NAMESPACE}"
  fi
  info "Release '${RELEASE}' already exists in namespace '${NAMESPACE}'; reconciling it in place."
fi

# True when the existing release already answers for a value, so this run has no
# business asking for one or generating one. Always false on a first install.
release_declares() {
  [[ "$RELEASE_EXISTS" == true ]] && "$1" "$RELEASE_VALUES"
}

# The database TLS CA cert path a values file names under
# `config.nodeExtraCaCerts`, or empty when it names none. Read the same shape
# declares_issuer/release_issuer use for the issuer: a top-level `config:`
# block naming the key.
#
# An explicitly EMPTY value reads back as empty, and that is the whole point:
# `--no-ca-cert` records `config.nodeExtraCaCerts: ""` in the release's own
# values, which is how the chart's configmap reads "no CA at all". A matcher
# that answered "this release has a CA" to that string left a release with no
# CA keeping the one it does not have, and the --db default below never
# applied on the re-run that most needed it.
ca_cert_in() {
  awk '
    /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top) }
    top == "config" && /^[[:space:]]+nodeExtraCaCerts:[[:space:]]*/ {
      v = $0
      sub(/^[[:space:]]+nodeExtraCaCerts:[[:space:]]*/, "", v)
      sub(/[[:space:]]+#.*/, "", v)
      gsub(/["'"'"']/, "", v)
      sub(/[[:space:]]+$/, "", v)
      # YAML nulls are a cert the release does not have, the same as "".
      if (v == "null" || v == "Null" || v == "NULL" || v == "~") { v = "" }
      print v; exit
    }
  ' "$1" 2>/dev/null || true
}

# True when the release's own recorded values already carry a CA cert to keep.
declares_ca_cert() {
  [[ -n "$(ca_cert_in "$1")" ]]
}

# The CA cert path the existing release already carries, or empty. Read for
# one purpose: naming which cert this run is keeping when the --db default
# below would otherwise --set over a custom CA the release already holds.
release_ca_cert() {
  ca_cert_in "$RELEASE_VALUES"
}

# `--reset-then-reuse-values` (applied to HELM_CMD further down) and the
# `helm get metadata`/`helm history` reads the version-adopt block just below
# this both need helm 3.14+. Checked here, once, before either one runs, so a
# reconcile on an older helm fails on ITS OWN unmet requirement instead of
# reaching the version-adopt block and failing on "helm get metadata: unknown
# command" with no explanation of why that command doesn't exist.
if [[ "$RELEASE_EXISTS" == true ]] \
   && ! helm upgrade --help 2>/dev/null | grep -q -- '--reset-then-reuse-values'; then
  fatal "This helm has no --reset-then-reuse-values (added in helm 3.14), and reconciling '${RELEASE}' without it either resets every value you set at install time or pins the old chart's defaults over the new chart's, and cannot read the deployed version safely either. Upgrade helm, or run \`helm upgrade\` yourself against your own values file."
fi

# The newest revision of the release whose status is one of the `|`-separated
# list in $1. Empty when there is none.
#
# `helm get metadata` with no --revision answers for the LAST revision, not
# the one actually serving traffic: after a failed upgrade (the new revision
# FAILED, the previous one is still `deployed`), the last revision is the
# failed one, and adopting its version would move the install to the very
# version that just failed to roll out. `helm history` is what names which
# revision holds which status; `revision_chart_version` then reads the one
# this picks.
#
# `|| true` on BOTH branches. A failing `helm history` under `pipefail` makes
# the pipeline non-zero, and the caller assigns this in a plain
# `VAR="$(release_revision ...)"`, which `set -e` exits on: the run would end
# on the "reconciling it in place" line with no error of its own. Answering
# empty instead reaches the refusal, which names what to do.
release_revision() {
  local want="$1"
  if command -v jq >/dev/null 2>&1; then
    helm history "$RELEASE" --namespace "$NAMESPACE" -o json 2>/dev/null \
      | jq -r --arg want "$want" \
          '($want | split("|")) as $w | [.[] | select(.status as $st | $w | index($st))] | sort_by(.revision) | last | .revision // empty' \
          2>/dev/null || true
  else
    # No jq: `helm history -o yaml` is a flat list of flat records, in a fixed
    # field order (revision, updated, status, chart, app_version, then
    # description; sigs.k8s.io/yaml preserves JSON key order), so "revision"
    # always precedes the "status" it belongs to and a sequential scan cannot
    # attribute one record's status to a different record's revision. The
    # first key of each record is rendered on the same line as the list
    # marker ("- revision: 1"), every other key on its own 2-space-indented
    # line ("  status: deployed"), so both forms are matched and the value is
    # read from the last field either way.
    { helm history "$RELEASE" --namespace "$NAMESPACE" -o yaml 2>/dev/null \
      | awk -v want="$want" '
          BEGIN { n = split(want, list, "|"); for (i = 1; i <= n; i++) { ok[list[i]] = 1 } }
          /^- revision: |^  revision: / { r = $NF }
          /^- status: |^  status: /     { if ($NF in ok) print r }
        ' | tail -1; } || true
  fi
}

# The chart version one revision of the release was installed from, or empty.
# `|| true` for the same reason release_revision carries it.
revision_chart_version() {
  local rev="$1"
  [[ -n "$rev" ]] || return 0
  if command -v jq >/dev/null 2>&1; then
    helm get metadata "$RELEASE" --namespace "$NAMESPACE" --revision "$rev" -o json 2>/dev/null \
      | jq -r '.version // empty' 2>/dev/null || true
  else
    # No jq: `helm get metadata -o yaml` is a flat scalar document, so a
    # plain line match on `version:` cannot collide with a nested key of the
    # same name.
    { helm get metadata "$RELEASE" --namespace "$NAMESPACE" --revision "$rev" -o yaml 2>/dev/null \
      | sed -n 's/^version: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | head -1; } || true
  fi
}

# The statuses a revision can hold and still be one this run may reconcile on.
# `uninstalling` is deliberately absent: a release part-way through
# `helm uninstall` has resources mid-deletion, helm does not refuse an upgrade
# against it, and reinstalling over one is not what a re-run of this script
# means. That state refuses below and `report_pending_state` names the way out.
ATTEMPTED_STATUSES='failed|pending-install|pending-upgrade|pending-rollback|superseded'

# On an existing release, a run with no --version must not silently move the
# chart/image version. Nothing else in this script sets --version in that
# case: helm's own OCI resolution defaults an unset --version to the newest
# published tag, and so does the Docker Hub lookup just below when
# verification runs. Neither one warns before doing it. Read the version off
# the release itself instead.
#
# Two revisions can answer, in this order:
#   - the newest `deployed` one, which is what is actually serving;
#   - failing that, the newest revision of any status, which is what the last
#     attempt named. A release whose every revision is `failed` or `pending-*`
#     is the ordinary shape of a first install that died in the migrate hook,
#     and that is precisely the release the failure report tells the operator
#     to run this installer against again. Reconciling on the version that
#     attempt already named moves nothing; resolving the newest published tag
#     from Docker Hub would.
# Only a release that names no readable chart version at all is refused, and
# then --version is the one thing that can answer.
if [[ -z "$VERSION" ]] && [[ "$RELEASE_EXISTS" == true ]]; then
  ADOPT_REVISION="$(release_revision deployed)"
  ADOPT_FROM="deployed"
  if [[ -z "$ADOPT_REVISION" ]]; then
    ADOPT_REVISION="$(release_revision "$ATTEMPTED_STATUSES")"
    ADOPT_FROM="last-attempt"
  fi
  if [[ -z "$ADOPT_REVISION" ]]; then
    fatal "Release '${RELEASE}' exists in namespace '${NAMESPACE}' but none of its revisions is one this run can reconcile on: none is deployed, and none is a finished or failed install or upgrade. A release part-way through 'helm uninstall' is the usual cause. Finish or reverse that first, or pass --version X.Y.Z to reconcile on the version you intend. Check: helm history ${RELEASE} --namespace ${NAMESPACE}"
  fi
  ADOPT_VERSION="$(revision_chart_version "$ADOPT_REVISION")"
  if [[ -z "$ADOPT_VERSION" ]]; then
    fatal "Release '${RELEASE}' exists in namespace '${NAMESPACE}' but revision ${ADOPT_REVISION} names no chart version this run can read, so it cannot tell what version to reconcile on. Pass --version X.Y.Z to reconcile on the version you intend. Check: helm history ${RELEASE} --namespace ${NAMESPACE}"
  fi
  VERSION="$ADOPT_VERSION"
  if [[ "$ADOPT_FROM" == "deployed" ]]; then
    info "No --version given; keeping the version this release is already on (revision ${ADOPT_REVISION}): $VERSION"
  else
    info "No revision of '${RELEASE}' has reached 'deployed' status yet, so there is no running version to keep."
    info "Reconciling on the version its last attempt used (revision ${ADOPT_REVISION}): $VERSION"
  fi
fi

# Resolve a concrete version so the chart + image can be pinned AND verified.
# cosign needs a concrete tag, not a floating "latest". Only reached on a FIRST
# install: an existing release either adopted a version off its own revisions
# above, or this script already refused rather than reach here with VERSION
# still empty.
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

# Determine database mode.
#
# On an existing release, silence: the prompt below defaults to BUNDLED, so a
# re-run that only meant to correct the issuer would answer "1" for an operator
# with no terminal and hand an external-database install a bundled PostgreSQL.
# The release already names its database and --reset-then-reuse-values carries
# that forward; only --db or --bundled on THIS run changes it.
if [[ -n "$DB_URL" ]]; then
  info "Using external database"
  # The CA cert this run applies is resolved further down, next to where it is
  # sent, because the guards that decide it (operator_named,
  # values_files_declare) are declared below this block.
elif [[ "$BUNDLED" == "true" ]]; then
  info "Using bundled PostgreSQL (dev/test only)"
elif [[ "$RELEASE_EXISTS" == true ]]; then
  info "Keeping the database configuration the release already has. Pass --db <url> or --bundled to change it."
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

# values_files_declare <matcher-fn> — true when any values file the operator
# handed us satisfies the matcher, which is called with one filename. A function
# rather than a regexp because the two callers need different precision: one is
# looking for a top-level key, the other has to tell `config.externalUrl` from
# `database.externalUrl`, which a pattern anchored on indentation cannot.
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
  local arg
  for arg in ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
    [[ "$arg" == *"$1"* ]] && return 0
  done
  return 1
}

values_files_declare() {
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
  # `${EXTRA_ARGS[@]+...}`: expanding an EMPTY array under `set -u` is an
  # unbound-variable error on bash 3.2, which is what macOS ships. The guard
  # expands to nothing at all when the array is empty, and to the quoted
  # elements when it is not.
  local candidate prev="" file
  for candidate in "$EXTRA_VALUES" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}; do
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
          && "$1" "$part" \
          && return 0
      done
    fi
  done
  return 1
}

# True when the operator has already expressed an openshift.enabled preference,
# in any of the three ways they can reach the chart from here.
#
# Matches `openshift.enabled` rather than a bare `openshift`, because
# EXTRA_ARGS is the catch-all for unrecognized arguments and an OpenShift
# install carries the string in ordinary values: a Route hostname is
# `*.openshiftapps.com` on ROSA, and an internal registry mirror is
# `image-registry.openshift-image-registry.svc`. A bare substring match made
# the most likely OpenShift command the one that silently skipped the flag.
declares_openshift_block() {
  grep -q '^[[:space:]]*openshift:' "$1" 2>/dev/null
}

operator_set_openshift() {
  operator_named openshift.enabled && return 0
  values_files_declare declares_openshift_block
}

# True when the operator has already said what the Server's published identity
# is, by any route: --set config.externalUrl, an ingress host the chart derives
# it from, or either of those in a values file. Their answer stands; ours would
# be a --set, which beats a values file.
# The three shapes a values file can answer the issuer question with, and
# nothing else. They are the chart's own resolution order in `agledger.externalUrl`:
# config.externalUrl, then the first ingress host, then route.host. Leaving the
# Route out is not a smaller net, it is a wrong answer on OpenShift, which is
# the platform this script already detects and configures for: an operator who
# exposed the Server with `--set route.enabled=true --set route.host=...` and no
# config.externalUrl would be asked the question again on a re-run, and a run
# with no terminal answers it https://localhost.
#
# `externalUrl` alone is not one of them: `database.externalUrl` is the
# connection string on the standard external-database values file, and reading
# that as a published identity would skip the prompt on the most common file
# there is. `ingress:` alone is not one either, because `ingress.enabled: false`
# is the shipped default shape and derives no host. So the block a key sits
# under is tracked, and an exposure counts only when it actually names a host.
declares_issuer() {
  awk '
    /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top) }
    top == "config"  && /^[[:space:]]+externalUrl:[[:space:]]*[^[:space:]#]/ { found = 1 }
    top == "ingress" && /^[[:space:]]+enabled:[[:space:]]*true/            { ing_on = 1 }
    top == "ingress" && /^[[:space:]]+-?[[:space:]]*host:[[:space:]]*[^[:space:]#]/ { ing_host = 1 }
    top == "route"   && /^[[:space:]]+enabled:[[:space:]]*true/            { rt_on = 1 }
    top == "route"   && /^[[:space:]]+host:[[:space:]]*[^[:space:]#]/      { rt_host = 1 }
    END { exit (found || (ing_on && ing_host) || (rt_on && rt_host)) ? 0 : 1 }
  ' "$1" 2>/dev/null
}

operator_set_issuer() {
  [[ -n "$EXTERNAL_URL" ]] && return 0
  operator_named config.externalUrl && return 0
  { operator_named ingress.hosts && operator_named ingress.enabled=true; } && return 0
  { operator_named route.host && operator_named route.enabled=true; } && return 0
  values_files_declare declares_issuer && return 0
  # An existing release already answers this, and re-prompting would default to
  # https://localhost for an operator with no terminal: a re-run meant to add a
  # backup CronJob would re-issue the Server under a name it never had.
  release_declares declares_issuer
}

# The issuer the existing release publishes, or empty. Read for one purpose:
# saying out loud that a --external-url which differs from it splits the chain
# rather than corrects it. Rows already written keep the issuer they were signed
# with, and helm will apply the change without comment.
#
# Only the explicit config.externalUrl is read back. A release whose issuer is
# derived from an ingress or a Route publishes a host, not a URL, and the scheme
# the chart puts in front of it depends on the TLS block: reconstructing that
# here would risk warning about a difference that is only this script's own
# guess. `declares_issuer` above already stops such a release being re-issued;
# this is the narrower job of naming the value when we can read it verbatim.
release_issuer() {
  awk '
    /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top) }
    top == "config" && /^[[:space:]]+externalUrl:[[:space:]]*[^[:space:]#]/ {
      sub(/^[[:space:]]+externalUrl:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit
    }
  ' "$RELEASE_VALUES" 2>/dev/null || true
}

# The Server's published identity. AGLEDGER_EXTERNAL_URL is the issuer (`iss`)
# signed into every record, receipt and certificate, and it is permanent: rows
# already written keep the issuer they were signed with, so changing it later
# splits the chain rather than correcting it. The chart refuses to render a
# production install that supplies neither this nor an ingress host, which is
# why this asks rather than defaulting quietly.
if operator_set_issuer; then
  if [[ -n "$EXTERNAL_URL" ]]; then
    :
  elif operator_named config.externalUrl \
       || { operator_named ingress.hosts && operator_named ingress.enabled=true; } \
       || { operator_named route.host && operator_named route.enabled=true; } \
       || values_files_declare declares_issuer; then
    info "Using the external URL from your own configuration."
  else
    info "Keeping the external URL the release already publishes."
  fi
else
  echo ""
  echo "  Public URL this Server will be reachable at."
  echo "    Signed into every record as the issuer. Permanent: it cannot be"
  echo "    changed for rows already written."
  echo "    Press Enter for https://localhost if this node has no domain yet."
  echo ""
  ask EXTERNAL_URL "  External URL [https://localhost]: " "https://localhost" "--external-url <url>"
fi
if [[ -n "$EXTERNAL_URL" ]]; then
  info "Chain issuer: ${EXTERNAL_URL}"
  PRIOR_ISSUER="$(release_issuer)"
  if [[ -n "$PRIOR_ISSUER" && "$PRIOR_ISSUER" != "$EXTERNAL_URL" ]]; then
    info "The release currently publishes ${PRIOR_ISSUER}. Rows already written keep it,"
    info "so this is a second issuer on one chain, not a correction of the first."
  fi
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
# Whether the vault signing key already exists somewhere this install will read
# it from. `--set-file` beats the chart's own `lookup`-based preservation (helm
# merges all FileValues after all Values), so generating one unconditionally and
# passing it re-keys the chain on every re-run: entries written before it stay
# signed by a key the new Secret no longer carries, and `verifyChain` reports a
# break the operator never made.
#
# Three places it can already be, all of which mean "do not generate":
#   - the chart-managed release Secret, which the chart preserves by `lookup`;
#   - a `secrets.existingSecret` the operator owns, where the chart writes no
#     Secret at all, so a generated key would be printed and used by nothing;
#   - `secrets.vaultSigningKey` in the release's own values.
release_holds_vault_key() {
  [[ "$RELEASE_EXISTS" == true ]] || return 1
  [[ -n "$(kubectl get secret --namespace "$NAMESPACE" \
        -l "app.kubernetes.io/instance=${RELEASE}" \
        -o jsonpath='{.items[*].data.VAULT_SIGNING_KEY}' 2>/dev/null || true)" ]] && return 0
  release_declares declares_secrets_key
}

# `secrets.existingSecret:` or `secrets.vaultSigningKey:` with a value, under the
# top-level `secrets:` block. Same shape as the issuer matcher, and for the same
# reason: `existingSecret` also appears under `postgres` and under `ingress.tls`.
declares_secrets_key() {
  awk '
    /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top) }
    top == "secrets" && /^[[:space:]]+(existingSecret|vaultSigningKey):[[:space:]]*[^[:space:]#]/ { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$1" 2>/dev/null
}

VAULT_KEY=""
if operator_named secrets.vaultSigningKey || operator_named secrets.existingSecret; then
  info "Using the vault signing key from your own --set; not generating one."
elif release_holds_vault_key; then
  info "The release already holds a vault signing key; reusing it rather than generating one."
  info "Generating one here would re-key the chain and orphan every entry already signed."
else
  info "Generating ${SIGNING_ALGORITHM} vault signing key..."
  # The pod runs in the namespace the workload will run in, not whatever the
  # kubectl context points at: Pod Security Admission, quotas and image-pull
  # secrets are namespaced, so a keygen that passes in `default` says nothing
  # about the namespace being installed into, and a pod left behind by an
  # interrupted run is invisible from there. helm's --create-namespace runs
  # after the render, which is after this, so the namespace is made here.
  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    # Re-read on failure rather than trusting the create's exit status: two runs
    # racing here means the second one loses to AlreadyExists, which is the one
    # failure that is not a failure.
    kubectl create namespace "$NAMESPACE" >/dev/null 2>&1 \
      || kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
      || fatal "Namespace '${NAMESPACE}' does not exist and could not be created. Create it (kubectl create namespace ${NAMESPACE}) or install into one that exists."
  fi
  # POSIX sed to read the key, not `grep -oP`: PCRE lookbehind is GNU-only and
  # BSD grep (macOS) rejects -P outright. This script is piped straight from
  # curl to bash, so it stands alone and cannot use lib-compose's helper.
  # `--attach`, never `-it`. Under `curl ... | bash` the script's source is stdin,
  # and `-i` hands that pipe to the pod, which drains the rest of the script.
  # `--attach` streams the pod's output and waits for it to exit (what `--rm`
  # needs) without claiming stdin; `</dev/null` closes the door behind it.
  #
  # Output is KEPT, not sent to /dev/null. Everything that stops this pod
  # producing a key reports itself on stderr and nowhere else: a name still held
  # by an earlier run (AlreadyExists), a restricted PSA namespace refusing the
  # pod, an exhausted quota, an image the node cannot pull. Discarded, all four
  # are one empty string, and the script fell through to openssl or to a
  # "could not generate" that named none of them.
  # The key itself lands in here on the happy path, so it is created at 600
  # before anything writes to it. SECRET_DIR is already 700 and removed on exit.
  KEYGEN_LOG="${SECRET_DIR}/keygen.log"
  : > "$KEYGEN_LOG"
  chmod 600 "$KEYGEN_LOG"
  kubectl run agledger-keygen --rm --attach --restart=Never \
    --namespace "$NAMESPACE" \
    --image="$IMG_REF" \
    --command -- /nodejs/bin/node dist/scripts/generate-signing-key.js --algorithm "$SIGNING_ALGORITHM" \
    >"$KEYGEN_LOG" 2>&1 </dev/null || true
  VAULT_KEY=$(sed -n 's/^VAULT_SIGNING_KEY=\([^[:space:]][^[:space:]]*\).*/\1/p' "$KEYGEN_LOG" | head -1 || true)

  if [[ -z "$VAULT_KEY" ]]; then
    echo "  [!] The keygen pod produced no key. What it reported:" >&2
    if [[ -s "$KEYGEN_LOG" ]]; then
      sed 's/^/      /' "$KEYGEN_LOG" >&2
    else
      echo "      (nothing at all)" >&2
    fi
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
    ${SELF} --set-file secrets.vaultSigningKey=./vault-signing-key ..."

  info "Vault signing key generated"
fi

if [[ -n "$VAULT_KEY" ]]; then
  # No trailing newline: --set-file uses the file's bytes verbatim as the value.
  printf '%s' "$VAULT_KEY" > "${SECRET_DIR}/vault-signing-key"
  chmod 600 "${SECRET_DIR}/vault-signing-key"
fi
if [[ -n "$EXTERNAL_URL" ]]; then
  # Not a secret, but --set-file for the reason the database URL uses it:
  # helm's own --set parser splits a VALUE on unescaped commas, which silently
  # truncates a URL carrying one into the permanent issuer of every row.
  # --set-file reads the file's bytes verbatim, and the path is under
  # SECRET_DIR, which is already refused if it carries a separator.
  printf '%s' "$EXTERNAL_URL" > "${SECRET_DIR}/external-url"
fi

# Build the helm command as an ARRAY and run it directly. It used to be a string
# run through `eval`, where the pass-through arguments this script advertises
# were re-parsed as shell a second time.
#
# `upgrade --install`, not `install`: `helm install` refuses a name that is
# already in use, so correcting one value meant `helm uninstall` first, which on
# a bundled-PostgreSQL release takes the database with it. This form installs
# when there is nothing there and reconciles when there is.
HELM_CMD=(helm upgrade --install "$RELEASE" "$CHART")
HELM_CMD+=(--namespace "$NAMESPACE" --create-namespace)

if [[ "$RELEASE_EXISTS" == true ]]; then
  # Values the operator supplied at install time have to survive a reconcile:
  # without a reuse flag helm resets every one of them to the chart's defaults,
  # so a re-run that only meant to correct the issuer would also drop the
  # replica count, the ingress and the database.
  #
  # NOT `--reuse-values`, which re-coalesces the OLD chart's defaults over the
  # new one and silently pins whatever the new chart changed (an image tag, a
  # grace period). `--reset-then-reuse-values` takes the NEW chart's defaults,
  # lays the last release's own values over them, and then this run's flags.
  # Availability (helm 3.14+) was already checked above, before the
  # version-adopt block that also needs it.
  HELM_CMD+=(--reset-then-reuse-values)
fi

if [[ -n "$VAULT_KEY" ]]; then
  HELM_CMD+=(--set-file "secrets.vaultSigningKey=${SECRET_DIR}/vault-signing-key")
fi
if [[ -n "$EXTERNAL_URL" ]]; then
  HELM_CMD+=(--set-file "config.externalUrl=${SECRET_DIR}/external-url")
fi
if [[ "$SIGNING_ALGORITHM" == "es256" ]]; then
  # Dedicated chart value; never claim an extraEnv index an operator's own
  # values file or --set could collide with.
  HELM_CMD+=(--set config.allowNonDefaultSigningAlg=true)
fi
if [[ "$IS_OPENSHIFT" == true ]]; then
  if operator_set_openshift; then
    info "OpenShift detected; leaving openshift.enabled to your own configuration."
  elif release_declares declares_openshift_block; then
    info "OpenShift detected; leaving openshift.enabled to what the release already sets."
  else
    HELM_CMD+=(--set openshift.enabled=true)
    info "OpenShift detected (security.openshift.io API group present)."
    info "Setting openshift.enabled=true so the SCC assigns the uid instead of the chart"
    info "requesting 65532, which restricted-v2 refuses. Container hardening is unchanged."
  fi
fi

[[ -n "$VERSION" ]] && HELM_CMD+=(--version "$VERSION")

# DB_URL first, in the same order the database decision above announces it:
# `--bundled --db <url>` in one run prints "Using external database" up there,
# and reaching the bundled branch first sent the flag it never announced and
# never sent the URL.
if [[ -n "$DB_URL" ]]; then
  if operator_named database.externalUrl; then
    info "Using the database URL from your own --set; ignoring --db."
  else
    printf '%s' "$DB_URL" > "${SECRET_DIR}/database-url"
    chmod 600 "${SECRET_DIR}/database-url"
    HELM_CMD+=(--set-file "database.externalUrl=${SECRET_DIR}/database-url")
  fi
elif [[ "$BUNDLED" == "true" ]]; then
  HELM_CMD+=(--set postgres.bundled.enabled=true)
  # database.externalUrl wins over postgres.bundled.enabled in the chart, and
  # --reset-then-reuse-values lays the previous release's own values over the
  # chart defaults, so on a release that already names an external database the
  # bundled flag alone changes nothing: the run would report a bundled install
  # and reconcile the external one. Saying --bundled on this run clears it.
  # An operator's own --set is the exception, and wins anyway: EXTRA_ARGS is
  # appended after this, and helm takes the last --set of a key.
  if operator_named database.externalUrl; then
    info "Keeping the database URL from your own --set; --bundled sets the bundled flag only."
  else
    HELM_CMD+=(--set database.externalUrl="")
  fi
fi

# The database TLS CA cert, resolved and sent here rather than inside the
# --db branch above. `--ca-cert` and `--no-ca-cert` say what this Server
# should trust when it talks to its database, and that means the same thing on
# a reconcile that names no database as it does on a first install. Sent from
# inside that branch, `--no-ca-cert` on a plain reconcile set nothing, printed
# nothing, and left the release on the cert it already carried, while the
# header documents the flag without qualification.
#
# The headless default: `--db` with neither flag gets the same cert the
# interactive database menu offers, so a `curl | bash -s -- --db ...`
# one-liner reaches an Aurora/RDS database instead of failing the handshake.
# It runs the same way on a reconcile, so `--db` on the re-run after a TLS
# failure applies the cert the first run lacked. Three things outrank it, and
# all three are the operator having already answered: their own `--set`, their
# own values file, and a CA the release itself carries. `--set` and
# `--set-file` both beat a values file, and this default is a `--set`, so
# without those first two checks it would silently override an answer helm's
# own precedence says should win. A release whose recorded CA is EMPTY carries
# none (that is what --no-ca-cert writes), so it takes the default like any
# other release with none.
if [[ -z "$CA_CERT" ]] && [[ -n "$DB_URL" ]] && ! operator_named config.nodeExtraCaCerts; then
  if values_files_declare declares_ca_cert; then
    info "Using the TLS CA cert your own values file names."
  elif release_declares declares_ca_cert; then
    info "Keeping the TLS CA cert the release already has: $(release_ca_cert)"
  else
    CA_CERT="$DEFAULT_RDS_CA"
  fi
fi

if operator_named config.nodeExtraCaCerts; then
  # EXTRA_ARGS is appended after this and helm takes the last --set of a key,
  # so theirs wins whatever this sends. Sending one anyway and reporting it
  # would name a cert the render does not use.
  info "Using the TLS CA cert from your own --set."
elif [[ -n "$CA_CERT" && "$CA_CERT" != "none" ]]; then
  HELM_CMD+=(--set "config.nodeExtraCaCerts=$CA_CERT")
  info "Using TLS CA cert: $CA_CERT"
elif [[ "$CA_CERT" == "none" ]]; then
  # A reconcile's --reset-then-reuse-values carries the release's existing
  # config.nodeExtraCaCerts forward unless something on THIS run overrides
  # it, so --no-ca-cert has to --set it to empty rather than simply not
  # setting anything: an empty string is what configmap.yaml's
  # `{{- if .Values.config.nodeExtraCaCerts }}` reads as absent, dropping
  # NODE_EXTRA_CA_CERTS from the rendered env. Harmless on a first install,
  # where there is nothing to clear.
  HELM_CMD+=(--set "config.nodeExtraCaCerts=")
  info "Skipping the TLS CA cert (--no-ca-cert)."
fi

[[ -n "$EXTRA_VALUES" ]] && HELM_CMD+=(-f "$EXTRA_VALUES")
HELM_CMD+=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

# helm reports a failed hook as a single line naming the Job, and it
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
# lying around from an earlier attempt. Without this, a re-run that fails before
# the hook runs at all would find the old Job, and the operator would be told
# the database role cannot serve, under a report naming grants they have already
# applied, while helm's actual message scrolled off the top.
# `before-hook-creation` deletes and recreates the Job whenever the hook really
# runs, so a changed uid is exactly "this run got that far".
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
  echo "  installer again: it reconciles the release in place and does not need" >&2
  echo "  it removed first, so nothing already written is lost." >&2
}

# Identity of the migrate Job that already exists, read before helm runs. Same
# before-hook-creation reasoning as preflight_job_uid: the migrate hook runs
# first (weight -5, preflight is 0), so a failure here means preflight's own
# UID never changes and report_preflight below reports nothing, correctly.
#
# On the bundled-Postgres path the migrate Job is a normal resource named
# `-migrate-<revision>`, not a hook, so `before-hook-creation` never deletes
# the previous one and several coexist (24h TTL). An unsorted list from the
# API server reads alphabetically for small counts (`-migrate-1` before
# `-migrate-2`), which is oldest-first, the opposite of what a freshly failed
# run needs. Sort by creation time and take the newest.
migrate_job_uid() {
  local job
  job="$(kubectl get job --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=migrate" \
      --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"
  [[ -n "$job" ]] || return 0
  kubectl get "$job" --namespace "$NAMESPACE" -o jsonpath='{.metadata.uid}' 2>/dev/null || true
}

report_migrate() {
  local uid succeeded failed job pod log
  uid="$(migrate_job_uid)"
  if [[ -z "$uid" || "$uid" == "$MIGRATE_UID_BEFORE" ]]; then return 0; fi

  job="$(kubectl get job --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=migrate" \
      --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"
  if [[ -z "$job" ]]; then return 0; fi
  succeeded="$(kubectl get "$job" --namespace "$NAMESPACE" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
  if [[ "$succeeded" == "1" ]]; then return 0; fi
  failed="$(kubectl get "$job" --namespace "$NAMESPACE" -o jsonpath='{.status.failed}' 2>/dev/null || true)"
  if [[ -z "$failed" || "$failed" == "0" ]]; then return 0; fi

  pod="$(kubectl get pod --namespace "$NAMESPACE" \
      -l "app.kubernetes.io/instance=${RELEASE},app.kubernetes.io/component=migrate" \
      --sort-by=.metadata.creationTimestamp -o name 2>/dev/null | tail -1 || true)"
  log="$(kubectl logs "${pod:-$job}" --namespace "$NAMESPACE" --tail=-1 2>&1 || true)"

  echo "" >&2
  # A TLS handshake failure is one of several ways this fails (bad
  # credentials, a missing DDL grant, an unreachable host, a lock timeout, a
  # frozen-baseline checksum mismatch); let the log say which, the same as
  # report_preflight does for its own gate.
  echo "  The migration hook (${job#job/}) did not pass. Its report:" >&2
  echo "" >&2
  echo "    kubectl logs ${job} --namespace $NAMESPACE --tail=-1" >&2
  echo "" >&2
  # shellcheck disable=SC2001  # multi-line sed, parameter expansion not equivalent
  echo "$log" | sed 's/^/  /' >&2
  # Named only when the log actually shows a TLS handshake failure: a bad
  # grant or an unreachable host is not fixed by --ca-cert, and naming it on
  # every migrate failure sends the operator chasing a cert that was never
  # the problem.
  #
  # The whole command, not the flag on its own. The re-run is a reconcile of
  # this release, and a reconcile applies the CA only when a flag names one:
  # the database, the issuer and the signing key it already holds are carried
  # forward without being repeated. The version THIS run used is repeated,
  # because a flagless re-run reads the version off the release and a run that
  # was moving the release to a new one would otherwise reconcile the old
  # version back with nothing saying so.
  if grep -qiE 'unable to get local issuer certificate|self-signed certificate|certificate verify failed|SSL error|tls:' <<< "$log"; then
    echo "" >&2
    echo "  That looks like a TLS handshake failure against the database: it presented" >&2
    echo "  a certificate this Server has no root CA for. Re-run with the CA it needs:" >&2
    echo "" >&2
    echo "    ${SELF} --ca-cert ${DEFAULT_RDS_CA}${VERSION:+ --version ${VERSION}} --namespace ${NAMESPACE} --release ${RELEASE}" >&2
    echo "" >&2
    echo "  ${DEFAULT_RDS_CA} is bundled in the image and covers" >&2
    echo "  AWS RDS and Aurora. For another provider's root CA, name your own path" >&2
    echo "  inside the container in its place, or pass --no-ca-cert instead if this" >&2
    echo "  database does not require TLS. Either flag applies to a reconcile exactly" >&2
    echo "  as it does to a first install." >&2
  fi
  echo "" >&2
  echo "  Nothing was created if the hook never ran; if it ran partway, migrations" >&2
  echo "  already applied are skipped on a re-run. Apply what the report asks for," >&2
  echo "  then run this installer again: it reconciles the release in place and does" >&2
  echo "  not need it removed first." >&2
}

# The one state a re-run cannot clear, and it is printed on EVERY helm failure
# rather than from report_preflight. helm refuses a release left mid-operation
# before it runs a single hook, so there is no gate Job for that path to find
# and the advice would never reach the operator who needs it most: an
# interrupted first run is exactly the case a reconciling re-run exists for.
report_pending_state() {
  echo "" >&2
  echo "  If helm reported that another operation is in progress, an earlier run was" >&2
  echo "  killed mid-flight and the release is stuck pending. Clear that, then re-run" >&2
  echo "  this installer:" >&2
  echo "    helm list --namespace $NAMESPACE                   # shows pending-install / pending-upgrade" >&2
  echo "    helm rollback $RELEASE --namespace $NAMESPACE      # if it has a revision to go back to" >&2
  echo "    helm uninstall $RELEASE --namespace $NAMESPACE     # if it does not" >&2
}

if [[ "$RELEASE_EXISTS" == true ]]; then
  info "Reconciling AGLedger..."
else
  info "Installing AGLedger..."
fi
echo ""
MIGRATE_UID_BEFORE="$(migrate_job_uid)"
PREFLIGHT_UID_BEFORE="$(preflight_job_uid)"
if ! "${HELM_CMD[@]}"; then
  report_migrate
  report_preflight
  report_pending_state
  fatal "Install failed. See the error above."
fi

echo ""
if [[ "$RELEASE_EXISTS" == true ]]; then
  info "AGLedger reconciled. Waiting for pods..."
else
  info "AGLedger installed. Waiting for pods..."
fi

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
