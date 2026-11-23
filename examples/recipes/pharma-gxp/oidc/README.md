# Pharma GxP recipe: a person signs the release (Part 11 signer variant)

The recipe one directory up runs every actor, the QA signers included, on an AGLedger API
key. In this variant the QA release signer holds no AGLedger secret. They sign in to your
own identity provider in a browser (authorization code with PKCE), the token is exchanged
for a short-lived cert bound to the agent your operator bound to that person, and every
request they make is signed with the cert's key. The Server seals that signature into the
chain entry, so the accept verdict carries the person's IdP subject and a signature of
their own that an auditor re-checks offline. The verdict is sent with `signatureMeaning`,
so the entry also carries the electronic signature the Server builds from the token: the
person's printed name, the meaning, the Server time and the IdP identity. The proposer and the checker stay automations
on API keys.

The reference IdP is Keycloak 26. Any OIDC provider that signs people in with the
authorization-code flow works the same way.

## Files

| File | What it is |
|------|------------|
| `idp/realm-calder.json` | A Keycloak realm with one public client (`calder-qa-desk`: authorization code, PKCE required, no client secret, no password grant) and two people: the signer (`qa.release`) and a colleague who is not one (`lab.analyst`). Their passwords are `${...}` placeholders Keycloak fills from the environment at import. |
| `setup.sh` | The operator half. Reads the signer's subject from the IdP's directory, registers the realm as a trusted issuer that admits that subject alone, creates the signer's agent bound by `(iss, sub)`, and creates the proposer and the checker with an API key each. Mints no key for the signer. Writes `oidc.env`. Safe to re-run. |
| `walkthrough.mjs` | The run, on the published `@agledger/sdk`: one release signed by the person, a colleague refused a cert, two releases rendered in the person's name with an admin key, the cross-record check, offline verification, and the signed release's readable copy. |
| `package.json` | Pins the SDK version this was run against. |

## Run

On a Compose install (`./scripts/install.sh`), with the recipe's types registered
(`../register.sh`) and a platform key to hand:

```bash
# 1. Secrets for this realm: the two people's passwords and the Keycloak admin password.
( umask 077; for v in QA_RELEASE_PASSWORD LAB_ANALYST_PASSWORD KC_BOOTSTRAP_ADMIN_PASSWORD; do
    echo "$v=$(openssl rand -hex 24)"; done > idp/secrets.env )

# 2. The IdP, on the Compose network so the Server can reach it by name.
docker run -d --name keycloak --network compose_default -p 127.0.0.1:8080:8080 \
  -v "$PWD/idp/realm-calder.json:/opt/keycloak/data/import/realm.json:ro" \
  --env-file idp/secrets.env -e KC_BOOTSTRAP_ADMIN_USERNAME=admin \
  -e KC_HOSTNAME=http://keycloak:8080 -e KC_HOSTNAME_STRICT=false -e KC_HTTP_ENABLED=true \
  quay.io/keycloak/keycloak:26.0 start-dev --import-realm

# 3. Let the Server fetch the realm's keys from that one container, over plain HTTP.
docker inspect -f '{{(index .NetworkSettings.Networks "compose_default").IPAddress}}' keycloak
#    Add to compose/.env, with the address printed above:
#      SSRF_ALLOW_CIDRS=<that address>/32
#      SSRF_ALLOW_PLAIN_HTTP=true
#    then, from compose/:  docker compose up -d
#    SSRF_ALLOW_PLAIN_HTTP admits http:// for every outbound URL, so remove both lines
#    when you are done. With an IdP on a public https URL, this step is not needed.

# 4. The operator half (reads idp/secrets.env)
export AGLEDGER_API_URL=http://localhost:3001
export AGLEDGER_PLATFORM_KEY=agl_plt_...
./setup.sh

# 5. The run
npm install
npm run walkthrough:scripted     # submits the IdP's login form with the passwords from idp/secrets.env
```

`npm run walkthrough` is the interactive form: it prints the sign-in URL, the signer opens
it in a browser, and the script waits on `127.0.0.1:8977` for the redirect. It asks twice:
once to open the release, and once to sign, when the IdP asks the person already signed in
for their password again. It skips the colleague's refusal. The URL is on the origin the
IdP calls itself (`OIDC_ISSUER`), because its login form posts back there. With the
reference Keycloak that is `http://keycloak:8080`, so the signer's machine has to resolve
the name `keycloak` to the host running it; with your own IdP on its real URL, set
`OIDC_IDP_URL` and `OIDC_ISSUER` to it. Step 3 and 6 of the run need `python3` for
`../oq/crosscheck.py`.

The walkthrough writes every export, the Server's verification keys, the signer's two cert
keys, a case manifest and the signed release's readable copy (`<releaseId>.audit-export.html`)
to `exports/`. Check them as an auditor would, pinning the vault
key the installer printed (`Vault signing key pin: sha256:<hex>`):

```bash
npx @agledger/verify@2 exports/<releaseId>.audit-export.json \
  --trust-anchor sha256:<hex> \
  --keys exports/verification-keys.json --require-supplied-keys \
  --agent-keys exports/agent-keys.json
```

## The signature

The verdict the signer submits:

```json
{
  "verdict": "accept",
  "completionId": "<the release completion being signed>",
  "signatureMeaning": "approval",
  "checks": { "signerRole": "qa-release", "regulation": "21 CFR 11.50" },
  "notes": "Reviewed precondition check <id>. Approved: the batch record may be created."
}
```

The Server answers, and seals on the `OUTCOME_REPORTED` entry, the signature:

```json
{
  "meaning": "approval",
  "signerName": "Avery Quinn",
  "signerIss": "http://keycloak:8080/realms/calder",
  "signerSub": "<the signer's subject>",
  "signedAt": "2026-11-17T02:51:17.225Z"
}
```

Only the meaning comes from the request. `signerName` is the `name` claim of the token the
IdP issued for this sign-in (`GET /v1/auth/me` shows it as `oidc.name` before signing),
`signerIss` and `signerSub` are the person as the IdP knows them, and `signedAt` is the
Server's time. The meanings the Server takes are `authorship`, `review`, `approval` and
`responsibility`. It takes `signatureMeaning` only on a cert: an API key, an admin's or
one minted for the signer's agent, is refused with 422 `signature_requires_oidc_identity`.

`checks` is still stored verbatim and not validated, so whatever a site puts there (the role
and regulation here) is a label. Beside the signature the entry carries the identity of the
request: `actorOwnerId` (the signer's agent), `actorOidcIss` and `actorOidcSub`, and the
signer's own signature over the request, which the verifier re-checks against the cert key.

## What the walkthrough shows

- **The person resolves to their agent through a cert.** `GET /v1/auth/me` reports
  `authType: ephemeral_cert`, the bound agent, and the IdP subject. The cert exchange takes
  an authorization-code token as it takes a workload's: it reads issuer, audience, subject
  and scopes, not the grant.
- **A colleague in the same IdP gets no cert.** The trusted-issuer row lists the signer's
  subject (`subjectAllowlist`). `lab.analyst` signs in to the same client, holds a valid
  token for the same audience, and the exchange answers 401 `subject_not_allowlisted`.
- **The release is opened and signed by the person.** They open the release from the
  control plan under one cert. Before signing, the cross-record check runs over the
  exports. Then they authenticate again (`prompt=login`; the script refuses a token whose
  `auth_time` is more than a minute old) and render the accept verdict under a second cert.
- **Two ways an org admin key renders a verdict in the person's name.** The admin key
  renders the verdict itself, or it mints an API key for the signer's agent and renders it
  with that. Each is refused when it sends `signatureMeaning`, and admitted when it leaves
  it out and types "Avery Quinn, approval" into `checks`. The admin-rendered entry names the
  admin's org as the actor; the minted-key entry names the signer's agent. Neither carries
  a signature, an IdP subject or a request signature of the signer's.
- **The cross-record check tells them apart.** The case manifest lists the signer's agent
  with the issuer and subject it is bound to (`signers`). `../oq/crosscheck.py` holds every
  verdict by that agent to that subject and reads the meaning from the sealed signature,
  not from `checks`: the signed release holds, the admin-rendered one is flagged
  `signature`, `reporter` and `signer`, and the minted-key one `signature` and `signer`.
- **Offline verification.** Every chain verifies against the supplied verification keys,
  and the five entries the signer wrote on the signed release (create, propose, activate,
  the verdict and the settlement it caused) re-verify against the two cert keys.
- **The readable copy.** `GET /v1/records/{id}/audit-export?format=html` renders the signed
  release for a reviewer, with the signer's printed name, the meaning, the Server time and
  the IdP identity beside the completion signed. The page carries the JSON export too, so
  the same file verifies offline.

## Keeping admin keys away from signing

The engine lets an org admin key render a principal's verdict and mint a key for any agent
in its org. It refuses either one a signature, but a verdict without one still settles the
release, so a reader holds a bound signer's verdicts to the sealed `signature` and the
entry's subject, never to `checks`. What a site does about it:

- Give the signer no API key, as `setup.sh` does. A signer with a key can render a verdict
  without the IdP, and the entry will carry no signature and no subject.
- Keep `admin-standard` keys with the people who administer the Server, not with QA and
  not in any automation. The automations here run on agent keys. A reader that is party to
  no record (the writer in `../sor/`, an auditor's tooling) gets an `admin-observer` key,
  which reads and is refused every action.
- Put the bound signers in the case manifest and run the cross-record check on every
  release before the batch record is written, not only in the OQ. `../sor/writer.py`
  re-reads the release before it writes; a site that wants the write refused on an
  unbound signature adds the same comparison there.
- Archive the cert public keys with the exports. An export carries each agent signature
  and the cert thumbprint, not the key; `exports/agent-keys.json` is what makes the
  signer's signature checkable later.

## Where 21 CFR Part 11 lands

| Section | What it asks | In this variant | Stays with the site |
|---|---|---|---|
| 11.50 | A signed record shows the signer's printed name, the date and time, and the meaning of the signature, in its readable form as well. | `signature` on the verdict entry: `signerName` from the IdP token, `meaning`, `signedAt` (Server time). The readable copy (`audit-export?format=html`) shows all three. | The printed name the IdP holds for each person, which meaning each step asks for, and where it is displayed to the signer before they sign. |
| 11.70 | A signature is linked to its record so it cannot be removed, copied or transferred. | The verdict entry names the `completionId` it signs, whose `evidenceHash` is on the same chain; the entry is hash-linked and Server-signed, and carries the signer's signature over the request. | Nothing further for the ledger entry. The link from the release to the batch record in the MES is the receipt's `payloadHash`. |
| 11.100 | A signature is unique to one individual and not reassigned. | One agent per person, bound to one `(iss, sub)`; the cross-record check holds each verdict to it. | Verifying the person's identity before the binding, and the IdP's rule that a subject is never reissued. |
| 11.200(a) | A non-biometric signature uses at least two distinct identification components, and is used only by its owner. | The signer authenticates to the IdP for the signing itself. One sign-in yields one cert (a token is exchangeable once), and the cert lasts at most five minutes. | The IdP's login policy: password rules, a second factor, session limits. The entry seals the issuer, the subject, the cert and the IdP key that signed the token; it does not record when or how the person authenticated, and the Server sets no maximum age on the authentication. The `auth_time` check here is the walkthrough's, and the rest is the IdP's log. |
| 11.300 | Controls over identification codes and passwords. | None: the Server never sees them. | The IdP. |

## What bringing it up teaches

- **A person's token and a workload's are the same to the exchange.** Nothing on the
  trusted-issuer row says which grant produced a token, so a service account in the same
  realm with the `agledger` audience would be admitted as a person is. The row's
  `subjectAllowlist` is what keeps it to people: list each signer's subject, as `setup.sh`
  does, and every other subject is refused whatever agent it is bound to.
- **Read the signer's subject from the IdP's directory.** A person cannot be asked for a
  token at provisioning time the way a workload can. `setup.sh` looks the user up through
  Keycloak's admin API; with another IdP, pass `QA_SUBJECT`.
- **The IdP asserts the scopes.** The client's `agledger_scopes` claim here is
  `records:read`, `records:write`, `completions:read`, `audit:read` and `schemas:read`,
  which is enough to open a release and render its verdict.
- **An audit export is bound to a record's named agents.** The signer is party to the
  release but not to the check or the proposal, so the proposer, which is party to all
  three, takes the exports.

## Scope

- One signer, one IdP, one org. The complaint investigator signs the same way: bind a
  second person and open the case under their cert.
- The check evidence in the walkthrough is a fixed body. It exercises the signature, not
  the system of record; `../oq/run.sh` drives the real checker and writer.
- No delegated on-behalf-of. That needs an IdP that issues RFC 8693 delegation tokens.
