#!/usr/bin/env bash
# Software delivery (GitHub): AGLedger vertical recipe.
# Registers all contract types in this recipe against YOUR AGLedger Server.
#
# A recipe is a starting point you adapt, not a turnkey product. Stand it up,
# then keep / edit / rename / delete the types to fit how your shop actually runs.
#
# Requires: an AGLedger Server you administer, and an admin or platform key that
# carries the schemas:write scope. Reads two environment variables:
#   AGLEDGER_API_URL   e.g. https://agledger.internal.example
#   AGLEDGER_API_KEY   an admin/platform key with schemas:write
#
# Usage:
#   AGLEDGER_API_URL=... AGLEDGER_API_KEY=... ./register.sh
#
# Behavior: POSTs each type to /v1/schemas in dependency order. On a fresh org
# each lands as a clean v1. Re-running with a backward-compatible change registers
# a NEW version of that type; an incompatible change is rejected by the type's
# compatibility mode and printed as friction (a finding, not a retry). Every
# non-2xx prints the error envelope so you can see exactly what the Server said.
#
# RECIPE_FORCE=1 (DESTRUCTIVE): disable + delete each type before POSTing, so the
# recipe's exact schema lands as a fresh v1 regardless of what the org already has.
# The engine refuses to delete a type that has live records. Use only to reset a
# scratch org to the recipe's canonical shape, never against an org with real data.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${AGLEDGER_API_URL:?set AGLEDGER_API_URL to your Server URL}"
: "${AGLEDGER_API_KEY:?set AGLEDGER_API_KEY to an admin/platform key with schemas:write}"
API="$AGLEDGER_API_URL"; AK="$AGLEDGER_API_KEY"
FORCE="${RECIPE_FORCE:-0}"

fail=0
for f in "$HERE"/types/*.json; do
  type=$(jq -r .type "$f")
  if [[ "$FORCE" == "1" ]]; then
    curl -s -X PATCH  "$API/v1/schemas/$type/disable" -H "Authorization: Bearer $AK" >/dev/null 2>&1
    curl -s -X DELETE "$API/v1/schemas/$type"         -H "Authorization: Bearer $AK" >/dev/null 2>&1
  fi
  resp=$(curl -s -w $'\n%{http_code}' -X POST "$API/v1/schemas" \
      -H "Authorization: Bearer $AK" -H 'Content-Type: application/json' --data-binary "@$f")
  code="${resp##*$'\n'}"; json="${resp%$'\n'*}"
  if [[ "$code" == 2* ]]; then
    gate=$(jq -r 'if (.completionSchema // {} | length)>0 then (.defaultGateMode // "auto") else "notarize-only" end' "$f")
    echo "OK   $code  $type  (lifecycle=$gate, v$(echo "$json" | jq -r .version))"
  else
    echo "FRIC $code  $type"
    echo "$json" | jq -c '{error,detail,recoveryHint}' 2>/dev/null || echo "$json"
    fail=1
  fi
done

echo "----- recipe types now registered on this Server -----"
for f in "$HERE"/types/*.json; do
  t=$(jq -r .type "$f")
  curl -s "$API/v1/schemas/$t" -H "Authorization: Bearer $AK" \
    | jq -r '"\(.type)\tv\(.version)\t\(.status)\t\(if (.completionSchema.properties|length)>0 then (.defaultGateMode//"auto") else "notarize-only" end)"' 2>/dev/null
done
exit $fail
