#!/usr/bin/env bash
# Agent Work Context: AGLedger horizontal recipe.
# Registers the work-context-v1 contract type against YOUR AGLedger Server.
#
# Requires: an AGLedger Server you administer, and an admin or platform key that
# carries the schemas:write scope. Reads two environment variables:
#   AGLEDGER_API_URL   e.g. https://agledger.internal.example
#   AGLEDGER_API_KEY   an admin/platform key with schemas:write
#
# Registration is versioned: re-running against an org that already has the type
# lands a new version. This type declares compatibilityMode "none", so version
# evolution is not gated by the registry's backward check.
#
# Schema writes are rate-limited to 10/minute per key. A 429 is retried
# automatically after the server-stated wait, up to 5 attempts.
#
# RECIPE_FORCE=1 (DESTRUCTIVE): disable + delete each type before POSTing, so
# the recipe's exact schema lands as a fresh v1. The engine refuses the delete
# if the type has live records. Use only to reset a test org.
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
  attempt=0
  while :; do
    resp=$(curl -s -w $'\n%{http_code}' -X POST "$API/v1/schemas" \
        -H "Authorization: Bearer $AK" -H 'Content-Type: application/json' --data-binary "@$f")
    code="${resp##*$'\n'}"; json="${resp%$'\n'*}"
    [[ "$code" != "429" ]] && break
    attempt=$((attempt + 1))
    if [[ $attempt -gt 5 ]]; then break; fi
    wait=$(echo "$json" | jq -r '.retryAfterSeconds // 60' 2>/dev/null) || wait=60
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=60
    echo "WAIT 429  $type  (rate limited; retrying in ${wait}s, attempt $attempt/5)"
    sleep "$wait"
  done
  if [[ "$code" == 2* ]]; then
    gate=$(jq -r 'if (.completionSchema // {} | length)>0 then (.defaultGateMode // "auto") else "notarize-only" end' "$f")
    echo "OK   $code  $type  (lifecycle=$gate, v$(echo "$json" | jq -r .version))"
  else
    echo "FRIC $code  $type"
    echo "$json" | jq -c '{error,detail,recoveryHint}' 2>/dev/null || echo "$json"
    fail=1
  fi
done

echo "----- recipe types now visible -----"
for f in "$HERE"/types/*.json; do
  t=$(jq -r .type "$f")
  curl -s "$API/v1/schemas/$t" -H "Authorization: Bearer $AK" \
    | jq -r '"\(.type)\tv\(.version)\t\(.status)\t\(if (.completionSchema.properties|length)>0 then (.defaultGateMode//"auto") else "notarize-only" end)"'
done
exit $fail
