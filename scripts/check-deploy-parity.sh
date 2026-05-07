#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — deploy/ ↔ install/ parity check
# =============================================================================
# Confirms the deploy/ tree (canonical) matches the install/ tree (mirror).
# mirror-install-repo.sh runs `rsync -a --delete deploy/ install/` at release —
# any install-only edit between releases is destroyed at the next mirror unless
# it has been backported to deploy/. This script catches drift before that
# happens.
#
# Usage:
#   ./deploy/scripts/check-deploy-parity.sh
#   INSTALL_REPO_PATH=/path/to/install ./deploy/scripts/check-deploy-parity.sh
#
# Exit codes:
#   0 — deploy/ and install/ are in sync
#   1 — drift detected (output describes what differs)
#   2 — install/ checkout missing or unreadable
#
# Recommended invocation:
#   - Run before tagging a release (mirror-install-repo.sh now does this).
#   - Run when you suspect install-only edits weren't backported.
# =============================================================================

API_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_REPO="${INSTALL_REPO_PATH:-${HOME}/projects/install}"

if [[ ! -d "$INSTALL_REPO/.git" ]]; then
  echo "  [!] Install repo not found at $INSTALL_REPO" >&2
  echo "      Set INSTALL_REPO_PATH=/path/to/install or clone agledger-ai/install there." >&2
  exit 2
fi

DRIFT=0

# `diff -rq` compares content recursively and reports only files that differ
# or are missing. We use it instead of `rsync -ic` because rsync itemizes
# timestamp/perms drift as drift even when content matches — false positives
# every time the install/ checkout is `git pull`ed (mtime differs from the
# original write).

check_pair() {
  local src="$1"
  local dst="$2"
  local label="$3"
  shift 3
  local exclude_args=("$@")

  if [[ ! -d "$src" ]]; then
    echo "  [!] Source missing: $src" >&2
    DRIFT=1
    return
  fi
  if [[ ! -d "$dst" ]]; then
    echo "  [!] Mirror missing: $dst" >&2
    DRIFT=1
    return
  fi

  local diff_output
  diff_output=$(diff -rq "${exclude_args[@]}" "$src" "$dst" 2>&1 || true)

  if [[ -n "$diff_output" ]]; then
    echo "" >&2
    echo "  DRIFT in $label:" >&2
    # shellcheck disable=SC2001  # multi-line sed, parameter expansion not equivalent
    echo "$diff_output" | sed 's/^/    /' >&2
    DRIFT=1
  fi
}

# Mirror pairs — must stay in sync with mirror-install-repo.sh.
check_pair \
  "$API_REPO/deploy/scripts" \
  "$INSTALL_REPO/scripts" \
  "scripts/" \
  --exclude=mirror-install-repo.sh \
  --exclude=check-deploy-parity.sh

check_pair \
  "$API_REPO/deploy/compose" \
  "$INSTALL_REPO/compose" \
  "compose/" \
  --exclude='.env' \
  --exclude='.env.local' \
  --exclude='*.key' \
  --exclude='*.pem'

check_pair \
  "$API_REPO/deploy/helm/agledger" \
  "$INSTALL_REPO/helm/agledger" \
  "helm/agledger/"

# Single-file pairs.
if [[ -f "$API_REPO/deploy/tests/smoke-test.sh" ]]; then
  if ! diff -q "$API_REPO/deploy/tests/smoke-test.sh" "$INSTALL_REPO/tests/smoke-test.sh" >/dev/null 2>&1; then
    echo "" >&2
    echo "  DRIFT in tests/smoke-test.sh:" >&2
    # shellcheck disable=SC2001
    diff "$API_REPO/deploy/tests/smoke-test.sh" "$INSTALL_REPO/tests/smoke-test.sh" | sed 's/^/    /' >&2 || true
    DRIFT=1
  fi
fi

if ! diff -q "$API_REPO/deploy/cosign.pub" "$INSTALL_REPO/cosign.pub" >/dev/null 2>&1; then
  echo "" >&2
  echo "  DRIFT in cosign.pub" >&2
  DRIFT=1
fi

if [[ "$DRIFT" -ne 0 ]]; then
  echo "" >&2
  echo "  deploy/ and install/ have drifted." >&2
  echo "" >&2
  echo "  If the change was made in install/, backport it to deploy/ before mirroring —" >&2
  echo "  the next mirror-install-repo.sh run does 'rsync --delete' and will overwrite" >&2
  echo "  install/-only content. If the change was made in deploy/ post-release, this" >&2
  echo "  is expected; the next release will mirror it forward." >&2
  exit 1
fi

echo "  deploy/ ↔ install/ in sync." >&2
exit 0
