#!/usr/bin/env bash
# Pharma GxP recipe, Part 11 signer variant: the operator half.
#
# Registers your IdP as a trust anchor for the cert exchange (one row, appliesTo agent,
# scoped to one org), creates the QA signer's agent bound to one person by the (issuer,
# subject) pair the IdP puts in that person's tokens, and creates two automations
# (proposer, checker) with an API key each. The person gets no AGLedger key.
#
# Env:
#   AGLEDGER_API_URL       your Server
#   AGLEDGER_PLATFORM_KEY  a platform key (trusted issuers are platform-only)
#   AGLEDGER_ORG_ID        optional; defaults to the only org on the Server
#   OIDC_IDP_URL           the realm as THIS host reaches it (default http://localhost:8080/realms/calder)
#   OIDC_ISSUER            the `iss` the IdP writes into its tokens, which is also the URL the
#                          Server fetches the realm's keys from (default http://keycloak:8080/realms/calder)
#   QA_USERNAME            the signer's username in the IdP (default qa.release)
#   KC_BOOTSTRAP_ADMIN_PASSWORD  Keycloak's admin password, to look the signer's subject up in
#                          the IdP's directory. Read from idp/secrets.env unless already set.
#                          With another IdP, set QA_SUBJECT to the person's `sub` instead.
#
# Writes oidc.env beside this script (mode 600): the agent ids, URLs and the automations'
# API keys walkthrough.mjs reads. Safe to re-run: the trust row and the agents are reused
# (the signer re-bound to the subject the IdP holds now), and the automations get fresh keys.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
API="${AGLEDGER_API_URL:?set AGLEDGER_API_URL}"; PLT="${AGLEDGER_PLATFORM_KEY:?set AGLEDGER_PLATFORM_KEY}"
IDP="${OIDC_IDP_URL:-http://localhost:8080/realms/calder}"
ISS="${OIDC_ISSUER:-http://keycloak:8080/realms/calder}"
QA_USER="${QA_USERNAME:-qa.release}"
for bin in curl jq; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
step(){ echo; echo "== $*"; }
api(){ # method path [body] -> body, then the status code on the last line
  curl -s -w $'\n%{http_code}' -X "$1" "$API$2" -H "Authorization: Bearer $PLT" -H 'Content-Type: application/json' ${3:+-d "$3"}
}

step "0. org"
ORG="${AGLEDGER_ORG_ID:-}"
if [ -z "$ORG" ]; then
  r=$(api GET /v1/admin/orgs); ORGS=$(echo "${r%$'\n'*}" | jq -r '.data[].id')
  [ "$(echo "$ORGS" | grep -c .)" = 1 ] || { echo "More than one org on this Server: set AGLEDGER_ORG_ID"; exit 1; }
  ORG="$ORGS"
fi
echo "OK   org $ORG"

step "1. the signer's subject, from the IdP's directory"
SUB="${QA_SUBJECT:-}"
if [ -z "$SUB" ]; then
  if [ -z "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ] && [ -f "$HERE/idp/secrets.env" ]; then
    KC_BOOTSTRAP_ADMIN_PASSWORD="$(sed -n 's/^KC_BOOTSTRAP_ADMIN_PASSWORD=//p' "$HERE/idp/secrets.env" | tail -1)"
  fi
  [ -n "${KC_BOOTSTRAP_ADMIN_PASSWORD:-}" ] || { echo "set QA_SUBJECT, or KC_BOOTSTRAP_ADMIN_PASSWORD (README, step 1)"; exit 1; }
  KC="${IDP%/realms/*}"; REALM="${IDP##*/realms/}"
  KT=$(curl -s -X POST "$KC/realms/master/protocol/openid-connect/token" -d grant_type=password -d client_id=admin-cli \
    -d username=admin --data-urlencode "password=$KC_BOOTSTRAP_ADMIN_PASSWORD" | jq -r '.access_token // empty')
  [ -n "$KT" ] || { echo "FAIL no admin token from $KC"; exit 1; }
  SUB=$(curl -s -G "$KC/admin/realms/$REALM/users" --data-urlencode "username=$QA_USER" -d exact=true -H "Authorization: Bearer $KT" | jq -r '.[0].id // empty')
fi
[ -n "$SUB" ] || { echo "FAIL no user $QA_USER in the IdP"; exit 1; }
echo "OK   $QA_USER is subject $SUB"

step "2. trust anchor: one row for the cert exchange, scoped to this org, admitting the signer alone"
# subjectAllowlist: the row admits the listed people and refuses every other subject the IdP
# issues a token for, a service account included. Add each signer you bind.
BODY=$(jq -nc --arg org "$ORG" --arg iss "$ISS" --arg sub "$SUB" '{orgId:$org, issuerUrl:$iss, expectedAudience:"agledger", appliesTo:"agent",
  claimMapping:{scopes:"agledger_scopes"}, maxCredentialTtlSeconds:300, subjectAllowlist:[$sub], label:"Calder Keycloak (QA signers)"}')
r=$(api POST /v1/admin/trusted-issuers "$BODY"); code="${r##*$'\n'}"; json="${r%$'\n'*}"
case "$code" in
  201) ROW=$(echo "$json" | jq -r .id); echo "OK   201 row $ROW, jwksUri discovered: $(echo "$json" | jq -r .jwksUri)";;
  409) r=$(api GET /v1/admin/trusted-issuers)
       ROW=$(echo "${r%$'\n'*}" | jq -r --arg iss "$ISS" --arg org "$ORG" \
         '.data[] | select(.issuerUrl==$iss and .expectedAudience=="agledger" and .appliesTo=="agent" and .orgId==$org) | .id' | head -1)
       [ -n "$ROW" ] || { echo "FAIL 409 $json"; exit 1; }
       r=$(api PATCH "/v1/admin/trusted-issuers/$ROW" "$(jq -nc --arg sub "$SUB" '{subjectAllowlist:[$sub], maxCredentialTtlSeconds:300}')"); c="${r##*$'\n'}"
       [ "$c" = 200 ] || { echo "FAIL $c updating row $ROW: ${r%$'\n'*}"; exit 1; }
       echo "OK   409 row already registered: $ROW (reused, allowlist set to the signer)";;
  *)   echo "FAIL $code $json"
       echo "     A 4xx naming the issuer usually means the Server cannot fetch $ISS/.well-known/openid-configuration."
       echo "     On a private network, allow it in compose/.env: SSRF_ALLOW_CIDRS=<the IdP's address>/32, and SSRF_ALLOW_PLAIN_HTTP=true for http."
       exit 1;;
esac

step "3. the signer: one agent bound to that person by (iss, sub)"
NAME="QA release signer ($QA_USER)"
r=$(api GET "/v1/admin/agents?orgId=$ORG&limit=100"); EXISTING="${r%$'\n'*}"
QA=$(echo "$EXISTING" | jq -r --arg n "$NAME" '.data[]? | select(.displayName==$n) | .id' | head -1)
if [ -n "$QA" ]; then
  r=$(api PATCH "/v1/agents/$QA" "$(jq -nc --arg iss "$ISS" --arg sub "$SUB" '{oidcIss:$iss, oidcSub:$sub}')"); c="${r##*$'\n'}"
  [ "$c" = 200 ] || { echo "FAIL $c re-binding the signer: ${r%$'\n'*}"; exit 1; }
  echo "OK   existing agent $QA re-bound to sub $SUB"
else
  r=$(api POST /v1/admin/agents "$(jq -nc --arg org "$ORG" --arg n "$NAME" --arg iss "$ISS" --arg sub "$SUB" \
    '{orgId:$org, displayName:$n, oidcIss:$iss, oidcSub:$sub}')"); c="${r##*$'\n'}"
  [ "$c" = 201 ] || { echo "FAIL $c creating the signer: ${r%$'\n'*}"; exit 1; }
  QA=$(echo "${r%$'\n'*}" | jq -r .id); echo "OK   new agent $QA bound to sub $SUB"
fi
echo "     no API key is minted for this agent: the person signs under a cert or not at all"

step "4. the automations: one agent and one API key each"
automation(){ # displayName -> "id key"
  local r c id key
  id=$(echo "$EXISTING" | jq -r --arg n "$1" '.data[]? | select(.displayName==$n) | .id' | head -1)
  if [ -z "$id" ]; then
    r=$(api POST /v1/admin/agents "$(jq -nc --arg org "$ORG" --arg n "$1" '{orgId:$org, displayName:$n}')"); c="${r##*$'\n'}"
    [ "$c" = 201 ] || { echo "FAIL $c creating $1: ${r%$'\n'*}" >&2; return 1; }
    id=$(echo "${r%$'\n'*}" | jq -r .id)
  fi
  r=$(api POST /v1/admin/api-keys "$(jq -nc --arg id "$id" '{ownerId:$id, ownerType:"agent", role:"agent", scopeProfile:"agent-full"}')"); c="${r##*$'\n'}"
  [ "$c" = 201 ] || { echo "FAIL $c minting a key for $1: ${r%$'\n'*}" >&2; return 1; }
  key=$(echo "${r%$'\n'*}" | jq -r .apiKey)
  echo "OK   $1 -> agent $id" >&2
  echo "$id $key"
}
read -r PROP PROP_KEY <<<"$(automation 'Batch proposer (Part 11 walkthrough)')"
read -r CHK CHK_KEY <<<"$(automation 'Precondition checker (Part 11 walkthrough)')"
[ -n "${PROP_KEY:-}" ] && [ -n "${CHK_KEY:-}" ] || { echo; echo "SETUP FAIL"; exit 1; }
# For the negative control only: an org admin key, which the engine lets render a principal's verdict.
r=$(api POST /v1/admin/api-keys "$(jq -nc --arg org "$ORG" '{ownerId:$org, ownerType:"org", role:"admin", scopeProfile:"admin-standard"}')"); c="${r##*$'\n'}"
[ "$c" = 201 ] || { echo "FAIL $c minting the admin key: ${r%$'\n'*}"; exit 1; }
ADMIN_KEY=$(echo "${r%$'\n'*}" | jq -r .apiKey)
echo "OK   an org admin key, used once by the walkthrough to show what an admin-rendered verdict looks like"

( umask 077
  {
    echo "AGLEDGER_API_URL=$API"
    echo "OIDC_IDP_URL=$IDP"
    echo "OIDC_ISSUER=$ISS"
    echo "QA_USERNAME=$QA_USER"
    echo "QA_AGENT_ID=$QA"
    echo "QA_SUBJECT=$SUB"
    echo "PROPOSER_AGENT_ID=$PROP"
    echo "PROPOSER_API_KEY=$PROP_KEY"
    echo "CHECKER_AGENT_ID=$CHK"
    echo "CHECKER_API_KEY=$CHK_KEY"
    echo "ADMIN_API_KEY=$ADMIN_KEY"
  } > "$HERE/oidc.env"
)
# umask covers only a file this run creates; one an earlier run wrote keeps its mode.
chmod 600 "$HERE/oidc.env"
echo; echo "SETUP PASS: row $ROW, signer $QA, written to oidc.env"
