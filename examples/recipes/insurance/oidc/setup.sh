#!/usr/bin/env bash
# Insurance recipe, OIDC workload-identity variant: the operator half.
#
# Registers your IdP as a trust anchor for the cert exchange (one row, appliesTo agent,
# scoped to one org) and creates one agent per workload, bound by the (issuer, subject)
# pair the IdP puts in that workload's tokens. The IdP is told nothing about AGLedger: no
# agent id, no custom claim beyond the scopes list the realm already carries.
#
# Env:
#   AGLEDGER_API_URL       your Server
#   AGLEDGER_PLATFORM_KEY  a platform key (trusted issuers are platform-only)
#   AGLEDGER_ORG_ID        optional; defaults to the only org on the Server
#   OIDC_TOKEN_URL         the realm's token endpoint as THIS host reaches it
#                          (default http://localhost:8080/realms/meridian/protocol/openid-connect/token)
#   OIDC_ISSUER            the `iss` the IdP writes into its tokens, which is also the URL the
#                          Server fetches the realm's keys from (default http://keycloak:8080/realms/meridian)
#   ADJUSTER_SECRET, SUPERVISOR_SECRET, AUDITOR_SECRET, UNBOUND_SECRET
#                          the realm's client secrets. Read from idp/secrets.env, the file the
#                          README generates and hands Keycloak, unless already set.
#
# Writes oidc.env beside this script (mode 600): the agent ids, URLs and client secrets
# walkthrough.mjs reads. Safe to re-run: an existing trust row and existing bound agents are reused.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for v in ADJUSTER_SECRET SUPERVISOR_SECRET AUDITOR_SECRET UNBOUND_SECRET; do
  # A value already in the environment wins over the file.
  if [ -z "${!v:-}" ] && [ -f "$HERE/idp/secrets.env" ]; then
    val="$(sed -n "s/^$v=//p" "$HERE/idp/secrets.env" | tail -1)"
    [ -n "$val" ] && printf -v "$v" '%s' "$val"
  fi
  [ -n "${!v:-}" ] || { echo "$v is not set: generate idp/secrets.env first (README, step 1)"; exit 1; }
done
API="${AGLEDGER_API_URL:?set AGLEDGER_API_URL}"; PLT="${AGLEDGER_PLATFORM_KEY:?set AGLEDGER_PLATFORM_KEY}"
TOKEN_URL="${OIDC_TOKEN_URL:-http://localhost:8080/realms/meridian/protocol/openid-connect/token}"
ISS="${OIDC_ISSUER:-http://keycloak:8080/realms/meridian}"
for bin in curl jq base64; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
fail=0
step(){ echo; echo "== $*"; }
api(){ # method path [body] -> body, then the status code on the last line
  curl -s -w $'\n%{http_code}' -X "$1" "$API$2" -H "Authorization: Bearer $PLT" -H 'Content-Type: application/json' ${3:+-d "$3"}
}
sub_of(){ # clientId secret -> the `sub` of one freshly minted token (the token is otherwise unused)
  local p; p=$(curl -s -X POST "$TOKEN_URL" -d grant_type=client_credentials -d "client_id=$1" -d "client_secret=$2" \
    | jq -r '.access_token // empty' | cut -d. -f2 | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  echo "$p" | base64 -d 2>/dev/null | jq -r '.sub // empty'
}

step "0. org"
ORG="${AGLEDGER_ORG_ID:-}"
if [ -z "$ORG" ]; then
  r=$(api GET /v1/admin/orgs); ORGS=$(echo "${r%$'\n'*}" | jq -r '.data[].id')
  [ "$(echo "$ORGS" | grep -c .)" = 1 ] || { echo "More than one org on this Server: set AGLEDGER_ORG_ID"; exit 1; }
  ORG="$ORGS"
fi
echo "OK   org $ORG"

step "1. trust anchor: one row for the cert exchange, scoped to this org"
BODY=$(jq -nc --arg org "$ORG" --arg iss "$ISS" '{orgId:$org, issuerUrl:$iss, expectedAudience:"agledger", appliesTo:"agent",
  claimMapping:{scopes:"agledger_scopes"}, maxCredentialTtlSeconds:600, label:"Meridian Keycloak (claims fleet)"}')
r=$(api POST /v1/admin/trusted-issuers "$BODY"); code="${r##*$'\n'}"; json="${r%$'\n'*}"
case "$code" in
  201) ROW=$(echo "$json" | jq -r .id); echo "OK   201 row $ROW, jwksUri discovered: $(echo "$json" | jq -r .jwksUri)";;
  409) # one row per (issuerUrl, expectedAudience, appliesTo, orgId): find the one already there
       r=$(api GET /v1/admin/trusted-issuers)
       ROW=$(echo "${r%$'\n'*}" | jq -r --arg iss "$ISS" --arg org "$ORG" \
         '.data[] | select(.issuerUrl==$iss and .expectedAudience=="agledger" and .appliesTo=="agent" and .orgId==$org) | .id' | head -1)
       [ -n "$ROW" ] && echo "OK   409 row already registered: $ROW (reused)" || { echo "FAIL 409 $json"; exit 1; };;
  *)   echo "FAIL $code $json"
       echo "     A 4xx naming the issuer usually means the Server cannot fetch $ISS/.well-known/openid-configuration."
       echo "     On a private network, allow it in compose/.env: SSRF_ALLOW_CIDRS=<the IdP's range>, and SSRF_ALLOW_PLAIN_HTTP=true for http."
       exit 1;;
esac

step "2. one agent per workload, bound by (iss, sub) read off a real token"
r=$(api GET "/v1/admin/agents?orgId=$ORG&limit=100"); EXISTING="${r%$'\n'*}"
agent_for(){ # displayName clientId secret -> agent id
  local sub id c; sub=$(sub_of "$2" "$3")
  [ -n "$sub" ] || { echo "FAIL no token from $TOKEN_URL for $2" >&2; return 1; }
  id=$(echo "$EXISTING" | jq -r --arg n "$1" '.data[]? | select(.displayName==$n) | .id' | head -1)
  if [ -n "$id" ]; then
    r=$(api PATCH "/v1/agents/$id" "$(jq -nc --arg iss "$ISS" --arg sub "$sub" '{oidcIss:$iss, oidcSub:$sub}')"); c="${r##*$'\n'}"
    [ "$c" = 200 ] || { echo "FAIL $c re-binding $1: ${r%$'\n'*}" >&2; return 1; }
    echo "OK   $1 ($2) -> existing agent $id, bound to sub $sub" >&2
  else
    r=$(api POST /v1/admin/agents "$(jq -nc --arg org "$ORG" --arg n "$1" --arg iss "$ISS" --arg sub "$sub" \
      '{orgId:$org, displayName:$n, oidcIss:$iss, oidcSub:$sub}')"); c="${r##*$'\n'}"
    [ "$c" = 201 ] || { echo "FAIL $c creating $1: ${r%$'\n'*}" >&2; return 1; }
    id=$(echo "${r%$'\n'*}" | jq -r .id)
    echo "OK   $1 ($2) -> new agent $id, bound to sub $sub" >&2
  fi
  echo "$id"
}
ADJ=$(agent_for "Claims adjuster (OIDC)"   claims-adjuster   "$ADJUSTER_SECRET")   || fail=1
SUP=$(agent_for "Claims supervisor (OIDC)" claims-supervisor "$SUPERVISOR_SECRET") || fail=1
AUD=$(agent_for "Claims auditor (OIDC)"    claims-auditor    "$AUDITOR_SECRET")    || fail=1
echo "     unbound-workload is deliberately left unbound: the walkthrough shows its exchange refused"
[ "$fail" = 0 ] || { echo; echo "SETUP FAIL"; exit 1; }

( umask 077
cat > "$HERE/oidc.env" <<EOF
AGLEDGER_API_URL=$API
OIDC_TOKEN_URL=$TOKEN_URL
ADJUSTER_AGENT_ID=$ADJ
SUPERVISOR_AGENT_ID=$SUP
AUDITOR_AGENT_ID=$AUD
ADJUSTER_SECRET=$ADJUSTER_SECRET
SUPERVISOR_SECRET=$SUPERVISOR_SECRET
AUDITOR_SECRET=$AUDITOR_SECRET
UNBOUND_SECRET=$UNBOUND_SECRET
EOF
)
# umask covers only a file this run creates; one an earlier run wrote keeps its mode.
chmod 600 "$HERE/oidc.env"
echo; echo "SETUP PASS: row $ROW, agents written to oidc.env"
