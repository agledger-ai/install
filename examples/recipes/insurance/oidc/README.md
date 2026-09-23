# Insurance recipe: OIDC workload identity

The insurance recipe one directory up runs every actor on an AGLedger API key. This variant
runs the same claim flow with no AGLedger secret in any agent's environment. Each workload
authenticates with a token from your own identity provider, exchanges it for a short-lived
cert, and signs every request with the key that cert is bound to. The Server seals that
signature into the chain entry, so each write carries the workload's own signature, which
an auditor can re-check offline.

The reference IdP is Keycloak 26. Any OIDC provider that issues client-credentials tokens
works the same way; the Keycloak-specific setting is called out below.

## Files

| File | What it is |
|------|------------|
| `idp/realm-meridian.json` | A Keycloak realm with four service-account clients: adjuster, supervisor, a read-only auditor, and one workload deliberately left unbound. The client secrets are development values for a throwaway realm. |
| `setup.sh` | The operator half. Registers the realm as a trusted issuer and creates one agent per workload, bound by the `(iss, sub)` pair read off a real token. Writes `oidc.env`. Safe to re-run. |
| `walkthrough.mjs` | The agents' half, on the published `@agledger/sdk`. Two claims, four refusals the Server must make, and offline verification of every chain and every agent signature. |
| `package.json` | Pins the SDK version this was run against. |

## Run

On a Compose install (`./scripts/install.sh`), with the insurance types registered
(`../register.sh`) and a platform key to hand:

```bash
# 1. The IdP, on the Compose network so the Server can reach it by name
docker run -d --name keycloak --network compose_default -p 127.0.0.1:8080:8080 \
  -v "$PWD/idp/realm-meridian.json:/opt/keycloak/data/import/realm.json:ro" \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=change-me \
  -e KC_HOSTNAME=http://keycloak:8080 -e KC_HOSTNAME_STRICT=false -e KC_HTTP_ENABLED=true \
  quay.io/keycloak/keycloak:26.0 start-dev --import-realm

# 2. Let the Server fetch the realm's keys over the private network. Add to compose/.env:
#      SSRF_ALLOW_CIDRS=172.16.0.0/12
#      SSRF_ALLOW_PLAIN_HTTP=true
#    then, from compose/:  docker compose up -d

# 3. The operator half
export AGLEDGER_API_URL=http://localhost:3001
export AGLEDGER_PLATFORM_KEY=agl_plt_...
./setup.sh

# 4. The agents' half: no AGLedger key in its environment
npm install
npm run walkthrough
```

`setup.sh` reaches the realm at `localhost:8080` and tells the Server it lives at
`http://keycloak:8080`, which is also the `iss` in every token because of `KC_HOSTNAME`.
Override with `OIDC_TOKEN_URL` and `OIDC_ISSUER` if yours differ. With an IdP on a public
https URL, step 2 is not needed.

The walkthrough writes every export, the Server's verification keys and the two agents'
cert keys to `exports/`. Check them with the published verifier as an auditor would:

```bash
npx @agledger/verify exports/<recordId>.audit-export.json \
  --keys exports/verification-keys.json --require-out-of-band-keys \
  --agent-keys exports/agent-keys.json
```

## What the walkthrough shows

- **Each workload resolves to its agent through a cert.** `GET /v1/auth/me` reports
  `authType: ephemeral_cert`, the bound agent, and the `sub` it answered to.
- **Two claims.** One inside the adjuster's authority, settled by the engine's auto gate. One
  over it: the auto gate fails, and the supervisor renders the settlement verdict under its
  own cert.
- **Four refusals:**
  - A workload no agent is bound to cannot exchange. The 400 lists the three ways to bind it.
  - A token exchanged once is refused a second time (`409 OIDC_JTI_REPLAY`).
  - A cert whose IdP asserted read-only scopes cannot write (`403` naming `records:write`).
  - An agent that is not party to a record cannot export it (`403 WRONG_STRUCTURAL_ROLE`).
- **Offline verification.** Every chain verifies against out-of-band keys, and every sealed
  agent signature re-verifies against the cert keys. The same exports verified without the
  agent keys report the signatures as present but unchecked.

## The CLI and the MCP server on a token

Both take a command that prints a fresh IdP token, run on every cert exchange. Leave
`AGLEDGER_API_KEY` unset:

```bash
export AGLEDGER_API_URL=http://localhost:3001
export AGLEDGER_OIDC_TOKEN_CMD='curl -s -X POST http://localhost:8080/realms/meridian/protocol/openid-connect/token -d grant_type=client_credentials -d client_id=claims-adjuster -d client_secret=adjuster-secret-1 | jq -r .access_token'
agledger auth --json          # credential: oidc-cert, the adjuster's agent id
agledger-mcp --api-url "$AGLEDGER_API_URL"   # agledger_discover reports the cert identity
```

In a real fleet the command is whatever your platform already uses to hand a workload its
identity token, such as `gcloud auth print-identity-token` or `kubectl create token`.

## What bringing it up teaches

- **Make the IdP issue single-audience tokens.** Keycloak's default access token carries
  `aud: ["agledger", "account"]`. With more than one audience the Server requires
  `expectedAzp` on the trusted-issuer row, which names one client, and there is one row per
  issuer, audience and org. So on default settings one realm serves one workload per org:
  the second client's row is refused `409`, and its token against the first row is refused
  `401 wrong_audience`. Set `fullScopeAllowed: false` on each client (the realm file here
  does): the token carries only `agledger`, and one row with no `expectedAzp` serves the
  whole fleet.
- **Bind from a token, not from config.** A Keycloak service account's `sub` is the
  service-account user's id and changes when the realm is re-imported. `setup.sh` reads it
  off a freshly minted token, and re-running it re-binds.
- **A cert's scopes are the IdP's word.** `claimMapping.scopes` on the row hands the scope
  decision to the IdP: the auditor client's `agledger_scopes` claim is `records:read` and
  `audit:read`, so its cert can read and nothing else. There is no AGLedger-side scope
  profile on this path; when a cert gets a 403, check the claim first.
- **Audit export is a structural action, not a read.** A read-scoped agent that is not party
  to a record cannot export it. The workload that did the work exports its own chains; the
  auditor verifies the files and needs no credential for that.
- **Archive the cert public keys.** An export carries each agent signature and the cert
  thumbprint, not the key. The SDK credential exposes `publicKeyJwk`, which is what
  `exports/agent-keys.json` holds. The CLI and the MCP server keep theirs in memory and
  discard them, so signatures they sealed can be re-checked only from the cert's issuance
  entry in a full vault dump, not from a per-record export.
- **Every write under a cert is signed, the principal's verdict included.** The run seals 24
  signatures across 13 chains: one per create, register, activate, propose, accept,
  completion and verdict.

## Scope

- No delegated on-behalf-of. That needs an IdP that issues RFC 8693 delegation tokens with an
  `act` claim, and stock Keycloak does not.
- One IdP, one org, one trusted-issuer row. Admin SSO is a separate door and not part of the
  claim flow.
