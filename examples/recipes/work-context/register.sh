#!/usr/bin/env bash
# Agent Work Context: AGLedger horizontal recipe.
# Registers the work-context-v1 contract type against YOUR AGLedger Server.
#
# Requires: an AGLedger Server you administer, and an admin key that carries
# the schemas:write scope (a platform key is refused: see below). Reads two environment variables:
#   AGLEDGER_API_URL   e.g. https://agledger.internal.example
#   AGLEDGER_API_KEY   an admin key with schemas:write
#
# work-context-v1 is one of the example types the Server seeds into each new
# Org, with the same schema as types/. This script registers it only for an Org
# that does not have it (created by a release that did not seed it, on an
# install with AGLEDGER_SEED_EXAMPLE_SCHEMAS=false, or deleted since) and leaves
# an existing one untouched.
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

# `local` is the label a registration without one takes. The reset and the
# read-back name it: a bare type name is refused with a 422 once the Org holds
# the type under a second publisher. The skip probe stays bare, so a type the
# Org already holds under one other publisher is skipped rather than
# registered a second time under this one.
PUBLISHER="${RECIPE_PUBLISHER:-local}"
fail=0
for f in "$HERE"/types/*.json; do
  type=$(jq -r .type "$f")
  existing=$(curl -s -w $'\n%{http_code}' "$API/v1/schemas/$type" -H "Authorization: Bearer $AK")
  if [[ "${existing##*$'\n'}" == "200" && "$FORCE" != "1" ]]; then
    status=$(echo "${existing%$'\n'*}" | jq -r '.status // "unknown"' 2>/dev/null)
    if [[ "$status" == "DISABLED" ]]; then
      echo "SKIP 200  $type  (registered in this Org but DISABLED: re-enable it with PATCH $API/v1/schemas/$type/enable)"
    else
      echo "SKIP 200  $type  (already registered in this Org)"
    fi
    continue
  fi
  if [[ "$FORCE" == "1" ]]; then
    curl -s -X PATCH  "$API/v1/schemas/$type/disable?publisher=$PUBLISHER" -H "Authorization: Bearer $AK" >/dev/null 2>&1
    curl -s -X DELETE "$API/v1/schemas/$type?publisher=$PUBLISHER"         -H "Authorization: Bearer $AK" >/dev/null 2>&1
  fi
  attempt=0
  while :; do
    # RECIPE_PUBLISHER registers each type under that publisher label rather
    # than `local`, which is what to set when the same types also arrive by
    # manifest import under a named publisher.
    body=$(jq -c --arg p "${RECIPE_PUBLISHER:-}" 'if $p == "" then . else . + {publisher: $p} end' "$f")
    resp=$(curl -s -w $'\n%{http_code}' -X POST "$API/v1/schemas" \
        -H "Authorization: Bearer $AK" -H 'Content-Type: application/json' --data-binary "$body")
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

echo "----- recipe types now visible under publisher $PUBLISHER -----"
for f in "$HERE"/types/*.json; do
  t=$(jq -r .type "$f")
  r=$(curl -s -w $'\n%{http_code}' "$API/v1/schemas/$t?publisher=$PUBLISHER" -H "Authorization: Bearer $AK")
  c="${r##*$'\n'}"; j="${r%$'\n'*}"
  if [[ "$c" == "200" ]]; then
    echo "$j" | jq -r '"\(.type)\tv\(.version)\t\(.status)\t\(if (.completionSchema.properties|length)>0 then (.defaultGateMode//"auto") else "notarize-only" end)"'
  else
    printf '%s' "$j" | jq -rn --arg t "$t" --arg c "$c" \
      '((try input catch null) // {}) as $e | "\($t)\tnot registered\t\($e.status // $c)\t\($e.detail // "")"'
  fi
done
exit $fail
