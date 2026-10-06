#!/usr/bin/env bash
# Healthcare prior-authorization — AGLedger vertical recipe.
# Registers all contract types in this recipe against YOUR AGLedger Server.
#
# A recipe is a starting point you adapt, not a turnkey product. Stand it up,
# then keep / edit / rename / delete the types to fit how your shop actually runs.
#
# Requires: an AGLedger Server you administer, and an admin key that carries
# the schemas:write scope (a platform key is refused: see below). Reads two environment variables:
#   AGLEDGER_API_URL   e.g. https://agledger.internal.example
#   AGLEDGER_API_KEY   an admin key with schemas:write
#
# Usage:
#   AGLEDGER_API_URL=... AGLEDGER_API_KEY=... ./register.sh
#
# Behavior: POSTs each type to /v1/schemas in dependency order. On a fresh org
# each lands as a clean v1. Re-running with an unchanged file answers 200 with the
# type's current version and registers nothing (no version slot spent). Re-running
# with a backward-compatible change registers a NEW version of that type; an incompatible change is rejected by the type's
# compatibility mode and printed as friction (a finding, not a retry). Every
# non-2xx prints the error envelope so you can see exactly what the Server said.
#
# Schema writes are rate-limited to 10/minute per key. A 429 is retried
# automatically after the server-stated wait, up to 5 attempts.
#
# RECIPE_FORCE=1 (DESTRUCTIVE): disable + delete each type before POSTing, so the
# recipe's exact schema lands as a fresh v1 regardless of what the org already has.
# The engine refuses to delete a type that has live records. Use only to reset a
# scratch org to the recipe's canonical shape — never against an org with real data.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${AGLEDGER_API_URL:?set AGLEDGER_API_URL to your Server URL}"
: "${AGLEDGER_API_KEY:?set AGLEDGER_API_KEY to an admin key with schemas:write}"
API="$AGLEDGER_API_URL"; AK="$AGLEDGER_API_KEY"
FORCE="${RECIPE_FORCE:-0}"

# A platform key registers each type for no Org: every Org can read it and no
# admin key can disable, edit or delete it. The recipe's types are meant to be
# ordinary types under your Org, so this takes an admin key and refuses others.
me=$(curl -s -w $'\n%{http_code}' "$API/v1/auth/me" -H "Authorization: Bearer $AK")
me_code="${me##*$'\n'}"; me_json="${me%$'\n'*}"
if [[ "$me_code" == "000" ]]; then
  echo "Could not reach $API (GET /v1/auth/me): check AGLEDGER_API_URL."
  exit 1
fi
if [[ "$me_code" != "200" ]]; then
  echo "AGLEDGER_API_KEY was refused by GET /v1/auth/me ($me_code):"
  echo "$me_json" | jq -c '{error,detail,recoveryHint}' 2>/dev/null || echo "$me_json"
  exit 1
fi
role=$(echo "$me_json" | jq -r '.role // empty')
if [[ "$role" != "admin" ]]; then
  echo "AGLEDGER_API_KEY is a ${role:-unknown} key. This recipe registers types under your Org, which takes an admin key with schemas:write."
  if [[ "$role" == "platform" ]]; then
    echo "A platform key would register them engine-wide, where no admin key can edit or delete them."
    echo "Mint an admin key with it (the org id is in GET $API/v1/admin/orgs), then re-run with AGLEDGER_API_KEY set to the key it returns:"
    echo "  curl -s -X POST $API/v1/admin/api-keys -H \"Authorization: Bearer \$AGLEDGER_API_KEY\" -H 'Content-Type: application/json' \\"
    echo "    -d '{\"role\":\"admin\",\"ownerType\":\"org\",\"ownerId\":\"<org id>\",\"scopeProfile\":\"admin-standard\"}'"
  fi
  exit 1
fi

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

echo "----- recipe types now registered on this Server -----"
for f in "$HERE"/types/*.json; do
  t=$(jq -r .type "$f")
  r=$(curl -s -w $'\n%{http_code}' "$API/v1/schemas/$t" -H "Authorization: Bearer $AK")
  c="${r##*$'\n'}"; j="${r%$'\n'*}"
  if [[ "$c" == "200" ]]; then
    echo "$j" | jq -r '"\(.type)\tv\(.version)\t\(.status)\t\(if (.completionSchema.properties|length)>0 then (.defaultGateMode//"auto") else "notarize-only" end)"' 2>/dev/null
  else
    printf '%s' "$j" | jq -rn --arg t "$t" --arg c "$c" \
      '((try input catch null) // {}) as $e | "\($t)\tnot registered\t\($e.status // $c)\t\($e.detail // "")"'
  fi
done
exit $fail
