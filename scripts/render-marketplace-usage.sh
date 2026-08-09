#!/usr/bin/env bash
# render-marketplace-usage.sh — render the AWS Marketplace listing's Usage
# Instructions for a release from the canonical template
# (deploy/marketplace/usage-instructions.tmpl), enforcing the two listing-copy
# constraints AWS checks: ASCII-only and <= 4000 characters.
#
# The rendered text goes to STDOUT — feed it into the Catalog API ChangeSet that
# sets `Instructions.Usage` on the new version's delivery option. The template is
# the version-controlled source of truth for the listing copy (it includes the
# "Verify provenance" digest cross-reference, since the Marketplace ECR image
# carries no Sigstore attestations — verify the public Docker Hub image and match
# the digest; see SECURITY.md).
#
# Usage: ./deploy/scripts/render-marketplace-usage.sh [version]
#   version defaults to package.json
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPL="$DEPLOY_DIR/marketplace/usage-instructions.tmpl"
VER="${1:-$(node -p "require('$DEPLOY_DIR/../package.json').version")}"

[ -f "$TMPL" ] || { echo "ERROR: template not found: $TMPL" >&2; exit 1; }

RENDERED=$(sed "s/__VERSION__/${VER}/g" "$TMPL")

# Constraint 1: ASCII-only. A non-ASCII char (e.g. an em-dash) makes the Catalog
# API return INVALID_USAGE_INSTRUCTIONS.
#
# `tr -d` over the ASCII range rather than `grep -P '[^\x00-\x7F]'`: BSD grep
# (macOS) has no -P and aborts. Deleting every ASCII byte leaves exactly the
# offending ones, which is also a more direct statement of the constraint.
# The per-line report matches anything outside printable ASCII (space through
# tilde) plus tab. Do NOT reach for `[[:print:]]` here: under LC_ALL=C, GNU grep
# treats the bytes of a UTF-8 em-dash as printable, so that class silently
# reports nothing on exactly the input this check exists to catch.
if [[ -n "$(printf '%s' "$RENDERED" | LC_ALL=C tr -d '\000-\177')" ]]; then
  echo "ERROR: rendered usage instructions contain non-ASCII characters:" >&2
  LC_ALL=C grep -n '[^ -~	]' <<<"$RENDERED" >&2 || true
  exit 1
fi

# Constraint 2: <= 4000 characters.
LEN=${#RENDERED}
if (( LEN > 4000 )); then
  echo "ERROR: rendered usage instructions are ${LEN} chars (max 4000)." >&2
  exit 1
fi

printf '%s\n' "$RENDERED"
echo "[render-marketplace-usage] OK: version=${VER}, length=${LEN}/4000, ASCII-only." >&2
