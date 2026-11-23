#!/usr/bin/env node
// Pharma GxP recipe, Part 11 signer variant: a batch release signed by a person.
//
// The QA release signer holds no AGLedger key. They sign in to your identity provider
// (authorization code with PKCE, in a browser), the token is exchanged for a short-lived
// cert bound to the agent the operator bound to that person, and every request they make
// is signed with the cert's key. The Server seals that signature into the chain entry, so
// the accept verdict on the release carries the person's IdP subject and a signature an
// auditor re-checks offline. The proposer and the checker are automations on API keys.
//
// What it drives:
//   1. the signer signs in; GET /v1/auth/me reports the cert, the agent and the subject.
//      Another person in the same IdP signs in and is refused a cert.
//   2. a release to the point of signature: proposal, release opened by the signer, check
//      delegated and completed, release completed by the proposer
//   3. the cross-record check (../oq/crosscheck.py) over the exports, before the signature
//   4. the signer authenticates again and signs: an accept verdict sent with
//      signatureMeaning, which the Server seals with the name and subject from the token
//   5. two negative controls, each a way an org admin key can put the signer's name on a
//      release: the admin key renders the verdict itself, and the admin key mints an API key
//      for the signer's agent and signs with that. The engine refuses signatureMeaning from
//      either, and admits the verdict sent without it, the name typed into `checks`. In both
//      exports the verdict entry carries no signature and no IdP subject, and the
//      cross-record check flags both.
//   6. every export verified offline against supplied keys, the signer's cert keys included,
//      and the signed release's readable copy (audit-export?format=html) written beside it
//
// The check evidence is a fixed body: this walkthrough exercises the signature, not the
// system of record. `oq/run.sh` drives the real checker against Odoo.
//
// Run: node --env-file=oidc.env walkthrough.mjs      (oidc.env is written by setup.sh)
//   Interactive: it prints a URL; the signer opens it and signs in, twice.
//   Scripted:    set QA_RELEASE_PASSWORD and the script submits the IdP's login form itself
//                (npm run walkthrough:scripted reads it from idp/secrets.env).
// Needs python3 for the cross-record check (standard library only).
import { AgledgerClient, oidcCertCredential, OidcExchangeError, AgledgerApiError } from '@agledger/sdk';
import { verifyExport } from '@agledger/sdk/verify';
import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { spawnSync } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, 'exports'); rmSync(OUT, { recursive: true, force: true }); mkdirSync(OUT, { recursive: true });
const E = process.env;
const BASE = E.AGLEDGER_API_URL, IDP = E.OIDC_IDP_URL, ISS = E.OIDC_ISSUER, QA_ID = E.QA_AGENT_ID, QA_SUB = E.QA_SUBJECT;
if (!BASE || !IDP || !ISS || !QA_ID || !QA_SUB || !E.PROPOSER_API_KEY || !E.CHECKER_API_KEY || !E.ADMIN_API_KEY) {
  console.error('Run setup.sh first, then: node --env-file=oidc.env walkthrough.mjs'); process.exit(2);
}
const CLIENT = E.OIDC_CLIENT_ID ?? 'calder-qa-desk', PORT = Number(E.OIDC_REDIRECT_PORT ?? 8977), REDIRECT = `http://127.0.0.1:${PORT}/callback`;
const RUN = String(Date.now()).slice(-6);
let fail = 0; const ok = (s) => console.log('OK  ', s); const bad = (s) => { fail = 1; console.log('FAIL', s); };
const step = (s) => console.log(`\n== ${s}`);
const sha = (s) => 'sha256:' + createHash('sha256').update(s).digest('hex');
const claimsOf = (jwt) => JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString());

// ---- the signer's half: authorization code with PKCE, redirect to a loopback listener ----
// `fresh` asks the IdP to authenticate the person again even if their browser session is
// live (prompt=login), and refuses a token whose auth_time is older than a minute.
let signerName = null;
async function signIn({ fresh = false, username = E.QA_USERNAME ?? 'qa.release', password = E.QA_RELEASE_PASSWORD } = {}) {
  const verifier = randomBytes(32).toString('base64url'), state = randomBytes(12).toString('hex');
  const q = new URLSearchParams({ client_id: CLIENT, response_type: 'code', scope: 'openid', redirect_uri: REDIRECT, state,
    code_challenge: createHash('sha256').update(verifier).digest('base64url'), code_challenge_method: 'S256', ...(fresh ? { prompt: 'login' } : {}) });
  const authUrl = `${IDP}/protocol/openid-connect/auth?${q}`;
  let server;
  const code = new Promise((resolve, reject) => {
    server = createServer((req, res) => {
      const u = new URL(req.url, REDIRECT);
      if (u.pathname !== '/callback') { res.writeHead(404).end(); return; }
      const good = u.searchParams.get('state') === state && u.searchParams.get('code');
      res.writeHead(good ? 200 : 400, { 'content-type': 'text/plain' }).end(good ? 'Signed in. You can close this tab.' : 'Sign-in failed.');
      if (good) resolve(u.searchParams.get('code'));
      else reject(new Error(`callback without a code: ${u.search.slice(0, 200)}`));
    }).listen(PORT, '127.0.0.1');
    setTimeout(() => reject(new Error('no sign-in within five minutes')), 300_000).unref();
  });
  try {
    if (password) {
      // Scripted: what the browser would do. The login page's form posts back to the IdP,
      // and the IdP redirects to the loopback listener with the code.
      const page = await fetch(authUrl, { redirect: 'manual' });
      const cookie = page.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ');
      const action = (await page.text()).match(/action="([^"]+)"/)?.[1]?.replaceAll('&amp;', '&');
      if (!action) throw new Error(`the IdP returned no login form (${page.status})`);
      // The reference Keycloak names itself keycloak:8080; reach it where this host does.
      const post = await fetch(action.replace(new URL(ISS).origin, new URL(IDP).origin), { method: 'POST', redirect: 'manual',
        headers: { 'content-type': 'application/x-www-form-urlencoded', cookie }, body: new URLSearchParams({ username, password }) });
      const loc = post.headers.get('location');
      if (!loc?.startsWith(REDIRECT)) throw new Error(`the IdP refused the sign-in (${post.status})`);
      await fetch(loc);
    } else {
      // The browser goes to the IdP under the name the IdP calls itself: its login form posts
      // back to that origin, and a session cookie set on any other name is not sent with it.
      console.log(`     ${fresh ? 'Sign in again to sign' : `Sign in as ${username}`}: ${authUrl.replace(new URL(IDP).origin, new URL(ISS).origin)}`);
    }
    const t = await fetch(`${IDP}/protocol/openid-connect/token`, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'authorization_code', code: await code, redirect_uri: REDIRECT, client_id: CLIENT, code_verifier: verifier }) });
    const j = await t.json();
    if (!t.ok) throw new Error(`token endpoint ${t.status}: ${JSON.stringify(j).slice(0, 200)}`);
    const c = claimsOf(j.access_token);
    if (fresh && !(Date.now() / 1000 - c.auth_time < 60)) throw new Error(`the IdP did not authenticate the signer again (auth_time ${c.auth_time})`);
    if (c.sub === QA_SUB) signerName = c.name ?? c.preferred_username ?? null;
    return j.access_token;
  } finally { server.close(); }
}
const session = (opts) => { const credential = oidcCertCredential({ getOidcToken: () => signIn(opts) }); return { credential, client: new AgledgerClient({ baseUrl: BASE, bearerToken: credential }) }; };

// ---- the automations' half: plain calls on API keys ----
async function call(key, method, path, body) {
  const r = await fetch(BASE + path, { method, headers: { authorization: `Bearer ${key}`, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw Object.assign(new Error(`${method} ${path} answered ${r.status}: ${JSON.stringify(j).slice(0, 300)}`), { status: r.status, body: j });
  return j;
}
const PROP = { id: E.PROPOSER_AGENT_ID, key: E.PROPOSER_API_KEY }, CHK = { id: E.CHECKER_AGENT_ID, key: E.CHECKER_API_KEY };
const REQUIRED = ['bom-active', 'component-lots-on-hand', 'component-lots-inspected', 'line-clear', 'lot-number-unique'];
const PLAN_REF = 'qc.test/1', PLAN_HASH = sha(JSON.stringify({ ref: PLAN_REF, questions: REQUIRED }));

// A release brought to the point of signature. `qa` is the signer's client (under a cert).
async function releaseToSignature(qa, lot) {
  const proposal = { productCode: 'API-INTERMEDIATE-7', bomRef: 'mrp.bom/1', quantity: 10, proposedLot: lot,
    componentLots: [{ productCode: 'SOLVENT-A', lotName: 'SOLV-2026-0142', quantity: 20 }], line: 'LINE-3',
    proposalHash: sha(`proposal-${lot}`), producedBy: { kind: 'rule-based' } };
  const prop = await call(PROP.key, 'POST', '/v1/records', { type: 'calder-batch-record-proposal-v1', principalAgentId: PROP.id, criteria: proposal });
  const rel = await qa.records.create({ type: 'calder-batch-record-release-v1', performerAgentId: PROP.id, gateMode: 'principal',
    criteria: { proposalRef: prop.id, proposalHash: proposal.proposalHash, productCode: proposal.productCode, lotNumber: lot, quantity: 10,
      requiredChecks: REQUIRED, controlPlanRef: PLAN_REF, controlPlanHash: PLAN_HASH, checkerAgentId: CHK.id, maxCheckAgeMinutes: 60, requestedBy: signerName ?? 'QA Release' } });
  await qa.records.transition(rel.id, 'propose');
  await call(PROP.key, 'POST', `/v1/records/${rel.id}/accept`, {});
  await qa.records.transition(rel.id, 'activate');
  const check = await call(PROP.key, 'POST', '/v1/records', { type: 'calder-precondition-check-v1', parentRecordId: rel.id, performerAgentId: CHK.id, autoActivate: true,
    maxSubmissions: 1, deadline: new Date(Date.now() + 3_600_000).toISOString(),
    criteria: { proposalRef: prop.id, productCode: proposal.productCode, controlPlanRef: PLAN_REF, controlPlanHash: PLAN_HASH } });
  const checks = REQUIRED.map((name) => ({ name, sourceSystem: 'walkthrough', sourceRef: 'n/a', observed: 'fixed body: no system was read', expected: 'fixed body', passed: true }));
  await call(CHK.key, 'POST', `/v1/records/${check.id}/completions`, { evidence: { requiredChecks: REQUIRED, controlPlanHash: PLAN_HASH, checks, passedChecks: REQUIRED, failedChecks: [],
    checkedAt: new Date().toISOString(), checkerKind: 'deterministic', evidenceDigest: sha(JSON.stringify(checks)) } });
  const done = await call(PROP.key, 'POST', `/v1/records/${rel.id}/completions`, { evidence: { checkRef: check.id, checkOutcome: 'FULFILLED', sorModel: 'mrp.production',
    lotNumber: lot, quantity: 10, payloadHash: sha(`payload-${lot}`) } });
  const status = (await call(PROP.key, 'GET', `/v1/records/${rel.id}`)).status;
  return { proposal: prop.id, release: rel.id, check: check.id, completion: done.id, status };
}
// The proposer is party to all three records, so it takes the exports (an audit export is
// bound to a record's named agents). ?evidence=true inlines each completion body.
async function exportCase(name, c, extra = {}) {
  for (const id of [c.release, c.check, c.proposal]) {
    writeFileSync(join(OUT, `${id}.audit-export.json`), JSON.stringify(await call(PROP.key, 'GET', `/v1/records/${id}/audit-export?evidence=true`), null, 2));
  }
  manifest.cases[name] = { flow: 'release', proposal: c.proposal, release: c.release, children: [c.check], ...extra };
  writeFileSync(join(OUT, 'case-manifest.json'), JSON.stringify(manifest, null, 2));
}
// signers: the provisioning record. The cross-record check holds every verdict by this agent to this subject.
const manifest = { signers: { [QA_ID]: { oidcIss: ISS, oidcSub: QA_SUB } }, cases: {} };
function crosscheck() {
  const r = spawnSync('python3', [join(HERE, '..', 'oq', 'crosscheck.py'), OUT], { encoding: 'utf8' });
  for (const line of (r.stdout ?? '').split('\n').filter((l) => l.startsWith('[') || l.startsWith('  '))) console.log('     ' + line);
  return r.status;
}
// What the site records beside the signature. The meaning, name, subject and time are the Server's.
const SITE_CHECKS = { signerRole: 'qa-release', regulation: '21 CFR 11.50' };
// What a key that is not the person can still send: the name typed in, as text.
const typedName = () => ({ ...SITE_CHECKS, signatureMeaning: 'approval', signerName, signedAt: new Date().toISOString() });
const reasonOf = (e) => /"reason":"([a-z_]+)"/.exec(JSON.stringify(e.body ?? ''))?.[1];

step('1. the signer signs in: a cert, not a key');
const opening = session();
const me = await opening.client.auth.getMe();
if (me.authType === 'ephemeral_cert' && me.ownerId === QA_ID && me.oidc?.iss === ISS && me.oidc?.sub === QA_SUB) ok(`${signerName}: authType=${me.authType} agent=${me.ownerId} sub=${me.oidc.sub} cert expires ${me.cert?.expiresAt}`);
else bad(`whoami: ${JSON.stringify({ authType: me.authType, ownerId: me.ownerId, oidc: me.oidc })}`);

// The trusted-issuer row lists the signer's subject. Anyone else the IdP signs in holds a
// valid token for the same audience and gets no cert.
if (!E.LAB_ANALYST_PASSWORD) console.log('     (skipped: the unlisted-person control runs in the scripted form, with LAB_ANALYST_PASSWORD set)');
else try {
  await session({ username: E.OTHER_USERNAME ?? 'lab.analyst', password: E.LAB_ANALYST_PASSWORD }).client.auth.getMe();
  bad('a person the row does not list obtained a cert');
} catch (e) {
  if (e instanceof OidcExchangeError && e.status === 401 && /subject_not_allowlisted/.test(JSON.stringify([e.reason, e.message, e.recoveryHint, e.body ?? '']))) ok(`another person in the same IdP is refused a cert: ${e.status} subject_not_allowlisted`);
  else bad(`unlisted person: ${e?.constructor?.name} ${e?.status} ${e?.message?.slice(0, 200)}`);
}

step('2. a release, to the point of signature');
const signed = await releaseToSignature(opening.client, `BATCH-2026-${RUN.slice(-3)}8`);
if (signed.status === 'PROCESSING') ok(`release ${signed.release} opened by the signer, check ${signed.check} FULFILLED, completion ${signed.completion} awaits the signature`);
else bad(`release ${signed.release} reads ${signed.status}`);

step('3. the cross-record check, before the signature');
await exportCase('signed', signed);
if (crosscheck() === 0) ok('the release holds: checkRef, checker, plan, age and proposal'); else bad('the cross-record check does not hold; the signer would stop here');

step('4. the signer authenticates again and signs');
const signing = session({ fresh: true });
let sealed = null;
try {
  const me2 = await signing.client.auth.getMe(); // the sign-in happens here, so signerName is the name on this session's token
  if (me2.oidc?.name === signerName) ok(`the Server reads the printed name it will seal from the token: ${me2.oidc.name}`);
  else bad(`GET /v1/auth/me oidc.name is ${JSON.stringify(me2.oidc?.name)}, the token's name claim is ${JSON.stringify(signerName)}`);
  const res = await signing.client.records.submitVerdict(signed.release, { completionId: signed.completion, verdict: 'accept', signatureMeaning: 'approval',
    checks: SITE_CHECKS, notes: `Reviewed precondition check ${signed.check}. Approved: the batch record may be created.` });
  sealed = res.signature ?? null;
  const s = sealed ?? {};
  if (s.meaning === 'approval' && s.signerName === signerName && s.signerIss === ISS && s.signerSub === QA_SUB && s.signedAt === res.reportedAt) ok(`signed: ${s.signerName}, ${s.meaning}, ${s.signedAt}, subject ${s.signerSub}`);
  else bad(`the verdict answered signature ${JSON.stringify(res.signature)}`);
  if (res.recordStatus === 'FULFILLED') ok(`accept verdict rendered under a second cert; release ${signed.release} reads ${res.recordStatus}`); else bad(`release reads ${res.recordStatus} after the verdict`);
} catch (e) { bad(`signing: ${e instanceof AgledgerApiError ? `${e.status} ${e.code} ` : ''}${e.message?.slice(0, 300)}`); }

step('5. negative controls: two ways an org admin key signs in the signer\'s name');
// Each key first asks for a signature, which the engine refuses, then renders the verdict
// without one, the name typed into checks, which it admits.
async function unsignedInTheSignersName(label, key, c, notes) {
  try {
    await call(key, 'POST', `/v1/records/${c.release}/verdict`, { completionId: c.completion, verdict: 'accept', signatureMeaning: 'approval', checks: SITE_CHECKS, notes });
    bad(`${label}: the engine sealed a signature for a key that is not the person`);
  } catch (e) {
    if (e.status === 422 && reasonOf(e) === 'signature_requires_oidc_identity') ok(`${label}: signatureMeaning is refused, 422 signature_requires_oidc_identity`);
    else bad(`${label}: signatureMeaning answered ${e.message.slice(0, 200)}`);
  }
  try {
    await call(key, 'POST', `/v1/records/${c.release}/verdict`, { completionId: c.completion, verdict: 'accept', checks: typedName(), notes });
    ok(`${label}: the verdict without signatureMeaning, "${signerName}, approval" typed into checks, is admitted: release ${c.release} reads ${(await call(PROP.key, 'GET', `/v1/records/${c.release}`)).status}`);
  } catch (e) { bad(`${label}: the unsigned verdict was refused, so this control shows nothing: ${e.message.slice(0, 200)}`); }
}
const admin = await releaseToSignature(opening.client, `BATCH-2026-${RUN.slice(-3)}9`);
await unsignedInTheSignersName('admin key', E.ADMIN_API_KEY, admin, 'Rendered with an org admin key, in the signer\'s name.');
const keyed = await releaseToSignature(opening.client, `BATCH-2026-${RUN.slice(-3)}7`);
try {
  const minted = await call(E.ADMIN_API_KEY, 'POST', '/v1/admin/api-keys', { ownerId: QA_ID, ownerType: 'agent', role: 'agent', scopeProfile: 'agent-full' });
  await unsignedInTheSignersName('a key minted for the signer\'s agent', minted.apiKey, keyed, 'Rendered with an API key an admin minted for the signer\'s agent.');
  await call(E.ADMIN_API_KEY, 'PATCH', `/v1/admin/api-keys/${minted.keyId}`, { isActive: false, reason: 'walkthrough negative control' });
  ok('the minted key is revoked');
} catch (e) { bad(`minting or revoking the signer's key: ${e.message.slice(0, 200)}`); }

step('6. the exports, verified offline');
await exportCase('signed', signed, { verdict: 'accept' });
await exportCase('admin-signed', admin, { verdict: 'accept', probe: 'admin-signed' });
await exportCase('key-signed', keyed, { verdict: 'accept', probe: 'key-signed' });
const keys = await opening.client.verificationKeys.list();
writeFileSync(join(OUT, 'verification-keys.json'), JSON.stringify(keys, null, 2));
const agentKeys = [opening.credential.publicKeyJwk, signing.credential.publicKeyJwk].filter(Boolean);
writeFileSync(join(OUT, 'agent-keys.json'), JSON.stringify({ keys: agentKeys }, null, 2));
const read = async (id) => call(PROP.key, 'GET', `/v1/records/${id}/audit-export?evidence=true`);
for (const [name, c] of [['signed', signed], ['admin-signed', admin], ['key-signed', keyed]]) {
  const exp = await read(c.release);
  const v = verifyExport(exp, { publicKeys: keys.data, requireSuppliedKeys: true, agentKeys });
  const entry = exp.entries.filter((e) => e.entryType === 'OUTCOME_REPORTED').at(-1);
  const who = { owner: entry?.actorOwnerId, role: entry?.actorRole, iss: entry?.actorOidcIss, sub: entry?.actorOidcSub };
  if (!v.valid || v.keyProvenance?.embedded !== 0) bad(`${name}: chain does not verify against supplied keys ${JSON.stringify(v.brokenAt ?? '').slice(0, 200)}`);
  if (name === 'signed') {
    if (who.owner === QA_ID && who.iss === ISS && who.sub === QA_SUB) ok(`signed: the verdict entry names agent ${who.owner} and IdP subject ${who.sub}`);
    else bad(`signed: verdict entry actor ${JSON.stringify(who)}`);
    const flat = (o) => JSON.stringify(Object.entries(o ?? {}).sort());
    if (sealed && flat(entry.payload.signature) === flat(sealed)) ok(`signed: the entry seals the signature the verdict answered: ${JSON.stringify(entry.payload.signature)}`);
    else bad(`signed: signature on the chain ${JSON.stringify(entry?.payload?.signature)}`);
    if (v.agentSignatures.present > 0 && v.agentSignatures.present === v.agentSignatures.verified) ok(`signed: ${v.agentSignatures.verified}/${v.agentSignatures.present} agent signatures on the release re-verify against the signer's two cert keys`);
    else bad(`signed: agent signatures present=${v.agentSignatures.present} verified=${v.agentSignatures.verified}`);
  } else if (name === 'admin-signed') {
    if (who.owner !== QA_ID && who.role === 'admin' && !who.sub && !entry.payload.signature) ok(`admin-signed: the verdict entry names ${who.role} ${who.owner}, no signature and no IdP subject, whatever its checks say`);
    else bad(`admin-signed: verdict entry actor ${JSON.stringify(who)}`);
  } else {
    if (who.owner === QA_ID && !who.sub && !entry.payload.signature) ok(`key-signed: the verdict entry names the signer's agent ${who.owner}, no signature and no IdP subject, and no request signature of the signer's (${v.agentSignatures.verified} on this release, from opening it)`);
    else bad(`key-signed: verdict entry actor ${JSON.stringify(who)}`);
  }
}
// The readable copy of the signed release: what a reviewer opens, with the signature's name,
// meaning and time shown beside the record (11.50(b)).
const html = await fetch(`${BASE}/v1/records/${signed.release}/audit-export?format=html`, { headers: { authorization: `Bearer ${PROP.key}` } });
const page = await html.text();
writeFileSync(join(OUT, `${signed.release}.audit-export.html`), page);
const esc = (s) => String(s).replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
if (html.ok && sealed && [sealed.signerName, sealed.meaning, sealed.signerSub].every((s) => page.includes(s) || page.includes(esc(s)))) ok(`signed: the readable copy shows ${sealed.signerName}, ${sealed.meaning} and the subject (exports/${signed.release}.audit-export.html)`);
else bad(`signed: format=html answered ${html.status} and does not show the signature`);
if (crosscheck() === 0) ok('the cross-record check holds for the signed release and flags the other two (signature, reporter, signer)'); else bad('the cross-record check did not come out as expected');

console.log(fail === 0 ? '\nWALKTHROUGH PASS' : '\nWALKTHROUGH FAIL'); process.exit(fail);
