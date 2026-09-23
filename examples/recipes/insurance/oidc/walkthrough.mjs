#!/usr/bin/env node
// Insurance recipe, OIDC workload-identity variant: the agents' half, on the published SDK.
//
// Three workloads authenticate to AGLedger with tokens from their own IdP and never hold an
// AGLedger secret: the adjuster (performer), the supervisor (principal) and a read-only
// auditor. `oidcCertCredential` does the exchange, refreshes the cert, and signs every
// request body with the key the cert is bound to; the Server seals that signature into the
// chain entry. The walkthrough drives two claims (within authority: auto gate; over
// authority: principal gate with a human-rendered verdict), then proves, offline and against
// out-of-band keys, that every chain verifies AND that the agents' own signatures re-verify
// against the cert keys the credentials exposed.
//
// Negative controls, each of which fails the run if it does not bite:
//   - a workload no agent answers to cannot exchange (400 naming the three ways to bind)
//   - a token exchanged once cannot be exchanged again (409 OIDC_JTI_REPLAY)
//   - a cert whose IdP asserted read-only scopes cannot write (403 naming the scope)
//   - the same exports verified WITHOUT agent keys report the signatures as unchecked
//
// Run: node --env-file=oidc.env walkthrough.mjs   (oidc.env is written by setup.sh)
// Env: AGLEDGER_API_URL, ADJUSTER_AGENT_ID, SUPERVISOR_AGENT_ID, AUDITOR_AGENT_ID, OIDC_TOKEN_URL,
//      and optionally the four client secrets. No AGLedger API key: that is the point.
import { AgledgerClient, oidcCertCredential, OidcExchangeError, AgledgerApiError } from '@agledger/sdk';
import { verifyExport } from '@agledger/sdk/verify';
import { generateKeyPairSync, sign } from 'node:crypto';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const AUD = join(HERE, 'exports'); rmSync(AUD, { recursive: true, force: true }); mkdirSync(AUD, { recursive: true });
const BASE = process.env.AGLEDGER_API_URL;
const TOKEN_URL = process.env.OIDC_TOKEN_URL ?? 'http://localhost:8080/realms/meridian/protocol/openid-connect/token';
const PERF_ID = process.env.ADJUSTER_AGENT_ID, PRIN_ID = process.env.SUPERVISOR_AGENT_ID, AUDITOR_ID = process.env.AUDITOR_AGENT_ID;
if (!BASE || !PERF_ID || !PRIN_ID || !AUDITOR_ID) { console.error('Run setup.sh first, then: node --env-file=oidc.env walkthrough.mjs'); process.exit(2); }
const RUN = process.env.RUNTAG ?? `OIDC-${process.pid}`;
let fail = 0; const ok = (s) => console.log('OK  ', s); const bad = (s) => { fail = 1; console.log('FAIL', s); };
const step = (s) => console.log(`\n== ${s}`);
const manifest = [];

// The IdP side: one client-credentials grant per exchange. Every call mints a fresh token
// (fresh jti), which is what the Server's one-exchange-per-token rule needs.
async function idpToken(clientId, secret) {
  const r = await fetch(TOKEN_URL, { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'client_credentials', client_id: clientId, client_secret: secret }) });
  if (!r.ok) throw new Error(`IdP token endpoint ${r.status} for ${clientId}`);
  return (await r.json()).access_token;
}
const workload = (clientId, secret) => {
  const credential = oidcCertCredential({ getOidcToken: () => idpToken(clientId, secret) });
  return { clientId, credential, client: new AgledgerClient({ baseUrl: BASE, bearerToken: credential }) };
};
const adjuster = workload('claims-adjuster', process.env.ADJUSTER_SECRET ?? 'adjuster-secret-1');
const supervisor = workload('claims-supervisor', process.env.SUPERVISOR_SECRET ?? 'supervisor-secret-1');
const auditor = workload('claims-auditor', process.env.AUDITOR_SECRET ?? 'auditor-secret-1');

step('1. who am I: each workload resolves to its agent through a cert, not a key');
for (const [w, want] of [[adjuster, PERF_ID], [supervisor, PRIN_ID], [auditor, AUDITOR_ID]]) {
  const me = await w.client.auth.getMe();
  if (me.authType === 'ephemeral_cert' && me.ownerId === want && me.oidc?.sub) ok(`${w.clientId}: authType=${me.authType} agent=${me.ownerId} sub=${me.oidc.sub} cert expires ${me.cert?.expiresAt} scopes=${me.scopes.length}`);
  else bad(`${w.clientId}: ${JSON.stringify({ authType: me.authType, ownerId: me.ownerId, want, oidc: me.oidc })}`);
}

step('2. negative: a workload no agent answers to is refused at the exchange');
try {
  await workload('unbound-workload', process.env.UNBOUND_SECRET ?? 'unbound-secret-1').client.auth.getMe();
  bad('unbound workload obtained a cert');
} catch (e) {
  if (e instanceof OidcExchangeError && e.status === 400 && /oidcSub/.test(e.recoveryHint ?? '')) ok(`unbound workload: OidcExchangeError ${e.status}, recoveryHint names the (iss, sub) binding: "${(e.recoveryHint ?? '').slice(0, 110)}..."`);
  else bad(`unbound workload: ${e?.constructor?.name} ${e?.status} ${e?.message?.slice(0, 200)}`);
}

step('3. negative: one token, one exchange');
{
  const jwt = await idpToken('claims-adjuster', process.env.ADJUSTER_SECRET ?? 'adjuster-secret-1');
  const sub = JSON.parse(Buffer.from(jwt.split('.')[1], 'base64url').toString()).sub;
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const body = JSON.stringify({ oidcToken: jwt, publicKeyJwk: { kty: 'OKP', crv: 'Ed25519', x: publicKey.export({ format: 'jwk' }).x },
    proofOfPossession: sign(null, Buffer.from(`agledger.oidc.cert.v1\n${sub}`), privateKey).toString('base64') });
  const post = () => fetch(`${BASE}/v1/auth/oidc/cert`, { method: 'POST', headers: { 'content-type': 'application/json' }, body });
  const first = await post(); const second = await post(); const sb = await second.json();
  if (first.status === 201 && second.status === 409 && sb.reason === 'OIDC_JTI_REPLAY') ok(`first exchange 201, replay 409 reason=${sb.reason}: "${(sb.recoveryHint ?? sb.detail ?? '').slice(0, 100)}"`);
  else bad(`replay: first ${first.status}, second ${second.status} ${JSON.stringify(sb).slice(0, 200)}`);
}

step('4. negative: the IdP asserts the scopes, and a read-only workload cannot write');
try {
  await auditor.client.records.create({ type: 'meridian-claim-intake-v1', criteria: { claimNumber: `${RUN}-X`, policyNumber: 'POL-X', lossDate: '2026-06-01', lossDescription: 'should never be written', insured: 'nobody', lossType: 'collision' } });
  bad('auditor cert (records:read, audit:read) created a record');
} catch (e) {
  if (e instanceof AgledgerApiError && e.status === 403 && /records:write/.test(e.message + JSON.stringify(e.details ?? '') + (e.recoveryHint ?? ''))) ok(`auditor cert refused 403 ${e.code}, names records:write`);
  else bad(`auditor write: ${e?.constructor?.name} ${e?.status} ${e?.code} ${e?.message?.slice(0, 160)}`);
}

// The claim flow, as the reference walkthrough drives it, with each actor on its own cert.
const rec = (claim, stage, row) => { manifest.push({ claim, stage, type: row.type, recordId: row.id, status: row.status }); return row; };
const notarize = (claim, stage, type, criteria) => adjuster.client.records.create({ type, criteria }).then((r) => rec(claim, stage, r));
async function autogate(claim, ceiling, proposed) {
  let g = await supervisor.client.records.create({ type: 'meridian-authority-band-v1', performerAgentId: PERF_ID, gateMode: 'auto',
    criteria: { claimNumber: claim, authorityBand: 'junior', authorityCeiling: { amount: ceiling, currency: 'USD' } } });
  await supervisor.client.records.transition(g.id, 'register'); await supervisor.client.records.transition(g.id, 'activate');
  await adjuster.client.completions.submit(g.id, { evidence: { proposedAmount: { amount: proposed, currency: 'USD' }, rationale: `adjuster proposes $${proposed} against band ceiling $${ceiling}` } });
  g = await adjuster.client.records.get(g.id); return rec(claim, 'authority-band', g);
}
async function settlementHuman(claim, coverageRef, bandRef, amount) {
  let s = await supervisor.client.records.create({ type: 'meridian-settlement-decision-v1', performerAgentId: PERF_ID, gateMode: 'principal',
    criteria: { claimNumber: claim, coverageCheckRef: coverageRef, authorityBandCheckRef: bandRef, authorityBand: 'senior' } });
  await supervisor.client.records.transition(s.id, 'propose');
  await adjuster.client.records.accept(s.id, 'adjuster takes the over-band settlement for supervisor review');
  await supervisor.client.records.transition(s.id, 'activate');
  const c = await adjuster.client.completions.submit(s.id, { evidence: { proposedAmount: { amount, currency: 'USD' }, coverage: 'collision full', rationale: 'over-band; supervisor reviewed and approved', overrideJustification: 'within senior authority after manual review of estimate + coverage' } });
  await supervisor.client.records.submitVerdict(s.id, { completionId: c.id, verdict: 'accept', checks: { decision: 'approved', basisOfDecision: 'manual senior review' } });
  s = await supervisor.client.records.get(s.id); return rec(claim, 'settlement-decision', s);
}
async function runClaim(claim, amount, expectBand) {
  step(`claim ${claim} ($${amount}, expect band ${expectBand})`);
  await notarize(claim, 'intake', 'meridian-claim-intake-v1', { claimNumber: claim, policyNumber: `POL-${claim}`, lossDate: '2026-06-01', lossDescription: 'vehicle collision, front-end damage, reported same day', insured: `Insured of ${claim}`, lossType: 'collision' });
  const cov = await notarize(claim, 'coverage', 'meridian-coverage-check-v1', { claimNumber: claim, coverageRef: `COV-${claim}`, determination: 'covered' });
  await notarize(claim, 'damage', 'meridian-damage-assessment-v1', { claimNumber: claim, estimateAmount: amount, method: 'adjuster-onsite', evidenceRef: `PHOTOS-${claim}` });
  await notarize(claim, 'fraud', 'meridian-fraud-score-v1', { claimNumber: claim, score: 12, referSIU: false });
  const band = await autogate(claim, 10000, amount);
  if (band.status === expectBand) ok(`authority band ${band.id} -> ${band.status}`); else bad(`authority band ${band.id} -> ${band.status}, expected ${expectBand}`);
  if (band.status === 'FAILED') {
    const s = await settlementHuman(claim, cov.id, band.id, amount);
    if (s.status === 'FULFILLED') ok(`settlement decision ${s.id} -> ${s.status} (principal verdict accept, rendered under the supervisor's cert)`); else bad(`settlement decision ${s.id} -> ${s.status}`);
  }
  await notarize(claim, 'outcome', 'meridian-settlement-outcome-v1', { claimNumber: claim, finalAmount: amount, currency: 'USD', postedToSorRef: `SOR-${claim}`, outcome: 'paid' });
}
await runClaim(`${RUN}-A`, 8000, 'FULFILLED');
await runClaim(`${RUN}-B`, 14500, 'FAILED');

step('5. the adjuster exports every chain it is party to; the auditor verifies the files offline');
// An audit export is a structural action bound to the record's named agents (or an org admin):
// a third agent, however read-scoped, resolves as org-member and is refused 403
// WRONG_STRUCTURAL_ROLE. So the workload that did the work hands the files over, and the
// auditor's job is done with no credential at all: files, out-of-band keys, cert keys.
try { await auditor.client.records.getAuditExport(manifest[0].recordId); bad('auditor (not party to the record) was allowed to export it'); }
catch (e) { if (e instanceof AgledgerApiError && e.status === 403 && e.code === 'WRONG_STRUCTURAL_ROLE') ok(`auditor cannot export a record it is not party to: 403 ${e.code}`); else bad(`auditor export: ${e?.status} ${e?.code} ${e?.message?.slice(0, 120)}`); }
const keys = await auditor.client.verificationKeys.list(); // unauthenticated route; the auditor cert is not needed for it
writeFileSync(join(AUD, 'verification-keys.json'), JSON.stringify(keys, null, 2));
const agentKeys = [adjuster.credential.publicKeyJwk, supervisor.credential.publicKeyJwk];
writeFileSync(join(AUD, 'agent-keys.json'), JSON.stringify({ keys: agentKeys }, null, 2));
writeFileSync(join(AUD, 'records.json'), JSON.stringify(manifest, null, 2));
let present = 0, verified = 0, chains = 0, unchecked = 0;
for (const m of manifest) {
  const exp = await adjuster.client.records.getAuditExport(m.recordId);
  writeFileSync(join(AUD, `${m.recordId}.audit-export.json`), JSON.stringify(exp, null, 2));
  const withKeys = verifyExport(exp, { publicKeys: keys.data, requireOutOfBandKeys: true, agentKeys });
  const without = verifyExport(exp, { publicKeys: keys.data, requireOutOfBandKeys: true });
  chains++;
  if (!withKeys.valid) bad(`${m.stage} ${m.recordId}: chain invalid ${JSON.stringify(withKeys.brokenAt ?? withKeys).slice(0, 200)}`);
  if (withKeys.keyProvenance?.embedded !== 0) bad(`${m.stage} ${m.recordId}: verified against an export-embedded key`);
  present += withKeys.agentSignatures.present; verified += withKeys.agentSignatures.verified;
  if (without.agentSignatures.verified !== 0) bad(`${m.stage} ${m.recordId}: agent signatures verified with no agent keys supplied`);
  unchecked += without.agentSignatures.present - without.agentSignatures.verified;
}
if (chains === manifest.length && fail === 0) ok(`${chains} chains verify against out-of-band keys (0 embedded)`);
if (present > 0 && present === verified) ok(`${verified}/${present} sealed agent signatures re-verify against the two cert keys the credentials exposed`);
else bad(`agent signatures present=${present} verified=${verified}`);
if (unchecked === present) ok(`without agent keys the same ${present} signatures are counted but not checked (the export carries no cert keys; archive them)`);
else bad(`without agent keys: expected ${present} unchecked, got ${unchecked}`);

console.log(fail === 0 ? '\nWALKTHROUGH PASS' : '\nWALKTHROUGH FAIL'); process.exit(fail);
