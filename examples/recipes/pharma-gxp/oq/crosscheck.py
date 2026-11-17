#!/usr/bin/env python3
"""Cross-record checks over a bundle of audit exports: what no single record can show.

The engine settles each gate and signs each record's chain. It does not read one record
from inside another, so these are compared here, from the exports alone, with no call to
the Server:

Complaint case
  children   the close-out's evidenceRecordIds equals the case's children, and each is an
             evidence read parented to the case
  stamps     the close-out's sorWriteStampDigest re-derives from the reads' sourceRecords,
             and no read reports mutating
  signature  the verdict entry carries a signature meaning and names the completion it signs
  reporter   the verdict was rendered by the case's principal under its own key
  status     the case reads FULFILLED after an accept and FAILED after a reject
  signer     when the manifest binds the principal to an identity provider subject, the
             verdict entry carries that issuer and subject (a verdict rendered with an
             API key carries none)

Release
  checkRef   the release completion's checkRef is a precondition check that is a child of
             this release, settled FULFILLED, and its gate closed before the release
             completion was submitted
  checker    that child's performer, and the agent that completed it, is the checker the
             release's criteria name (checkerAgentId)
  age        the check was no older than the release's maxCheckAgeMinutes when the release
             completion was submitted, when QA accepted and when the receipt was written
  proposal   the release's proposalHash, product, lot and quantity equal the proposal
             record's, and every check child names the same proposal
  plan       every check child's controlPlanRef and controlPlanHash equal the release's, and
             the checker's plan list and hash, as it read them, equal the release's
  receipt    the receipt's payloadHash equals the release completion's, it names the
             release, and it was written after the accept verdict; no receipt names a
             release that was not accepted, and none exists that the manifest does not list
  signature, reporter, status, signer   as above
  revision   no revision was requested on a release that a failed check holds

  evidence   (both flows) every completion body used hashes to the evidenceHash on the chain

Run it before QA signs as well as after: `checkRef`, `checker`, `plan` and `proposal` need
only the proposer's completion, and `age` is measured to whatever has happened so far.

    python3 oq/crosscheck.py [bundle directory, default oq-bundle]

The bundle is what `drive.py` writes, and what your own orchestration writes for a PQ:
  <record id>.audit-export.json   GET /v1/records/{id}/audit-export?evidence=true, one per
                                  record: each case or release, its children, the proposal
                                  and the receipt. With evidence=true each completion entry
                                  carries the body submitted beside the hash the chain signs
  case-manifest.json              {"cases": {name: {"flow": "complaint", "case": id, "children": [ids]}
                                                 | {"flow": "release", "release": id, "children": [ids],
                                                    "receipt": id or absent}},
                                   "signers": {agent id: {"oidcIss": ..., "oidcSub": ...}}}
                                  signers is optional: the people your provisioning record
                                  binds to an identity provider subject (see oidc/)
                                  children as GET /v1/records/{id}/sub-records lists them
Verify each export with `agledger-verify` first: this script trusts the entries it reads.

A case the driver marked as a probe has to be flagged, with exactly the findings the probe
exists to raise. Exit 0 iff every clean case holds and every probe is caught; 2 if the
bundle is absent. Assertions that hold are appended to `oq.log` in the bundle.
"""
import datetime
import glob
import hashlib
import json
import os
import sys

AUD = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "oq-bundle")
CASE_T, READ_T, CHECK_T, PROPOSAL_T = "calder-complaint-case-v1", "calder-evidence-read-v1", "calder-precondition-check-v1", "calder-batch-record-proposal-v1"
PROBES = {"no-check-child": {"checkRef"}, "check-cancelled": {"checkRef"},
          "proposer-is-checker": {"checker"}, "revision-after-failed-check": {"revision"}, "stale-check": {"age"},
          "admin-signed": {"reporter", "signer"}, "key-signed": {"signer"}}


def jcs(obj):
    """RFC 8785 canonical JSON, as the Server hashes a completion body. Enough of it for these bodies:
    sorted keys, no whitespace, and a whole-number float written as the integer JavaScript prints."""
    def norm(v):
        if isinstance(v, float) and v.is_integer() and abs(v) < 1e21:
            return int(v)
        if isinstance(v, dict):
            return {k: norm(x) for k, x in v.items()}
        if isinstance(v, list):
            return [norm(x) for x in v]
        return v
    return json.dumps(norm(obj), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def stamp_digest(stamps):
    """As sor/odoo.py: order-independent over (model, id, writeDate)."""
    key = sorted((s["model"], s["id"], s["writeDate"]) for s in stamps)
    return "sha256:" + hashlib.sha256(json.dumps(key, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def when(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def entries(rec, etype):
    return [e for e in rec["entries"] if e["entryType"] == etype]


def opening(rec):
    """The payload of the opening entry: RECORD_CREATED for a root, RECORD_DELEGATED for a child."""
    return rec["entries"][0]["payload"]


def final_status(rec):
    st = [e["payload"]["newStatus"] for e in rec["entries"] if e["payload"].get("newStatus")]
    return st[-1] if st else opening(rec).get("status")


def own_completion(rec, findings):
    """(completion id, evidence body, submitted at, submitting agent) of the performer's last completion, or Nones.
    The body is the one the export inlines (?evidence=true) and has to hash to what the chain bound."""
    subs = entries(rec, "COMPLETION_SUBMITTED")
    if not subs:
        return None, None, None, None
    e = subs[-1]
    cid = e["payload"]["completionId"]
    body = e.get("evidence")
    if body is None or hashlib.sha256(jcs(body)).hexdigest() != e["payload"].get("evidenceHash"):
        findings["evidence"] = "completion %s of %s: %s" % (cid, rec["recordId"], "the export carries no body (take it with ?evidence=true)" if body is None else "the body does not hash to the chain's evidenceHash")
        return cid, None, e["createdAt"], e["payload"].get("agentId")
    return cid, body, e["createdAt"], e["payload"].get("agentId")


def verdict_entry(rec):
    v = entries(rec, "OUTCOME_REPORTED")
    return v[-1] if v else None


def check_verdict(rec, findings, own_cid):
    """signature, reporter, status. Returns the verdict's outcome, or None when no verdict was rendered."""
    v = verdict_entry(rec)
    if not v:
        return None
    p, principal = v["payload"], opening(rec).get("principalAgentId")
    meaning = (p.get("checks") or {}).get("signatureMeaning")
    # an accept signs the performer's own completion; a reject signs that, or the completion the engine held the record on after a rollup
    held = [e["payload"].get("completionId") for e in entries(rec, "GATE_HELD") if e["chainPosition"] < v["chainPosition"]]
    signed_ok = p.get("completionId") and (p["completionId"] == own_cid if p.get("outcome") == "accept" else p["completionId"] in held + [own_cid])
    if not meaning or not signed_ok:
        findings["signature"] = "meaning %r, signs completion %s" % (meaning, p.get("completionId"))
    if not (p.get("reporterType") == "principal" and p.get("reporterId") == principal
            and v.get("actorRole") == "agent" and v.get("actorOwnerId") == principal):  # the signed actor fields, not the display ones
        findings["reporter"] = "rendered by %s %s (%s), principal is %s" % (v.get("actorRole"), v.get("actorOwnerId"), p.get("reporterType"), principal)
    bound = SIGNERS.get(principal)
    if bound and (v.get("actorOidcIss"), v.get("actorOidcSub")) != (bound.get("oidcIss"), bound.get("oidcSub")):
        findings["signer"] = "rendered under subject %s of %s, the principal is bound to %s of %s" % (v.get("actorOidcSub"), v.get("actorOidcIss"), bound.get("oidcSub"), bound.get("oidcIss"))
    after = [e["payload"]["newStatus"] for e in rec["entries"] if e["chainPosition"] > v["chainPosition"] and e["payload"].get("newStatus")]
    want = "FULFILLED" if p.get("outcome") == "accept" else "FAILED"
    if not after or after[0] != want:
        findings["status"] = "%s verdict, then the record reads %s" % (p.get("outcome"), after[0] if after else final_status(rec))
    return p.get("outcome")


def complaint(c, findings):
    case = R.get(c["case"])
    if not case:
        findings["children"] = "no export for the case %s" % c["case"]
        return
    kids = c.get("children", [])
    for k in kids:
        o = opening(R[k]) if k in R else {}
        if o.get("parentRecordId") != c["case"] or o.get("type") != READ_T:
            findings["children"] = "%s is not an exported evidence read parented to the case" % k
    cid, ev, _, _ = own_completion(case, findings)
    outcome = check_verdict(case, findings, cid)
    if ev is None:
        return outcome  # no close-out of the orchestrator's own: the case was held by rollup, and the verdict checks above are all there is
    if set(ev.get("evidenceRecordIds", [])) != set(kids) or not kids:
        findings["children"] = "the close-out names %d record(s), the case has %d children" % (len(ev.get("evidenceRecordIds", [])), len(kids))
    reads = [own_completion(R[k], findings)[1] for k in kids if k in R]
    stamps = [s for r in reads if r for s in r.get("sourceRecords", [])]
    if (None in reads or any(r.get("mutating") is not False for r in reads if r)
            or ev.get("sorWriteStampDigest") != stamp_digest(stamps) or ev.get("sorRecordsUnchanged") is not True):
        findings["stamps"] = "close-out digest %s, re-derived %s, mutating %s" % (str(ev.get("sorWriteStampDigest"))[:23], stamp_digest(stamps)[:23], [r and r.get("mutating") for r in reads])
    return outcome


def release(c, findings):
    rel = R.get(c["release"])
    if not rel:
        findings["checkRef"] = "no export for the release %s" % c["release"]
        return
    crit = opening(rel)["criteria"]
    kids = [k for k in c.get("children", []) if k in R and opening(R[k]).get("parentRecordId") == c["release"] and opening(R[k]).get("type") == CHECK_T]
    if len(kids) != len(c.get("children", [])):
        findings["plan"] = "a listed child is not an exported precondition check parented to the release"
    for k in kids:
        kc = opening(R[k])["criteria"]
        if (kc.get("controlPlanRef"), kc.get("controlPlanHash")) != (crit.get("controlPlanRef"), crit.get("controlPlanHash")):
            findings["plan"] = "check %s carries plan %s %s, the release %s %s" % (k, kc.get("controlPlanRef"), str(kc.get("controlPlanHash"))[:23], crit.get("controlPlanRef"), str(crit.get("controlPlanHash"))[:23])
        if kc.get("proposalRef") != crit.get("proposalRef"):
            findings["proposal"] = "check %s names proposal %s, the release %s" % (k, kc.get("proposalRef"), crit.get("proposalRef"))
    prop = R.get(crit.get("proposalRef"))
    pc = opening(prop)["criteria"] if prop and opening(prop).get("type") == PROPOSAL_T else None
    if pc is None:
        findings["proposal"] = "no exported proposal %s" % crit.get("proposalRef")
    elif (pc.get("proposalHash"), pc.get("productCode"), pc.get("proposedLot"), pc.get("quantity")) != (crit.get("proposalHash"), crit.get("productCode"), crit.get("lotNumber"), crit.get("quantity")):
        findings["proposal"] = "the proposal reads %s %s %s x%s, the release %s %s %s x%s" % (
            str(pc.get("proposalHash"))[:23], pc.get("productCode"), pc.get("proposedLot"), pc.get("quantity"),
            str(crit.get("proposalHash"))[:23], crit.get("productCode"), crit.get("lotNumber"), crit.get("quantity"))
    if entries(rel, "REVISION_REQUESTED") and any(final_status(R[k]) == "FAILED" for k in kids):
        findings["revision"] = "a revision was requested on a release whose check failed"

    cid, ev, submitted, _ = own_completion(rel, findings)
    outcome = check_verdict(rel, findings, cid)
    receipts = [r for r in R.values() if opening(r).get("type") == "calder-sor-write-receipt-v1" and opening(r)["criteria"].get("releaseRef") == c["release"]]
    if ev is not None:
        ref = ev.get("checkRef")
        if ref not in kids:
            findings["checkRef"] = "checkRef %s is not a check child of this release" % ref
        else:
            child = R[ref]
            closed = [e["createdAt"] for e in entries(child, "GATE_COMPLETE")]
            if final_status(child) != "FULFILLED" or not closed or max(closed) >= submitted:
                findings["checkRef"] = "check %s reads %s, gate closed %s, release completion submitted %s" % (ref, final_status(child), max(closed) if closed else "never", submitted)
            _, cev, checked, by = own_completion(child, findings)
            want = crit.get("checkerAgentId")
            if not want or opening(child).get("performerAgentId") != want or (by and by != want):
                findings["checker"] = "check performed by %s, completed by %s, expected checker %s" % (opening(child).get("performerAgentId"), by, want)
            if cev is not None and (cev.get("requiredChecks") != crit.get("requiredChecks") or cev.get("controlPlanHash") != crit.get("controlPlanHash")):
                findings["plan"] = "the checker read %s, the release requires %s" % (cev.get("requiredChecks"), crit.get("requiredChecks"))
            # how old the check was at each thing that relied on it: the completion, QA's accept, the write
            relied = [("the release completion", submitted)]
            if outcome == "accept":
                relied.append(("the accept verdict", verdict_entry(rel)["createdAt"]))
                relied += [("the receipt", r["entries"][0]["createdAt"]) for r in receipts]
            limit = crit.get("maxCheckAgeMinutes")
            late = [(what, (when(at) - when(checked)).total_seconds() / 60) for what, at in relied
                    if not isinstance(limit, int) or when(at) - when(checked) > datetime.timedelta(minutes=limit)] if checked else []
            if late:
                findings["age"] = "the check was %.1f minutes old at %s, the release allows %s" % (late[0][1], late[0][0], limit)

    if outcome == "accept":
        v = verdict_entry(rel)
        if [r["recordId"] for r in receipts] != ([c["receipt"]] if c.get("receipt") else []):
            findings["receipt"] = "%d receipt(s) name the release, the manifest names %s" % (len(receipts), c.get("receipt"))
        elif receipts and ev is not None and (opening(receipts[0])["criteria"].get("payloadHash") != ev.get("payloadHash") or receipts[0]["entries"][0]["createdAt"] <= v["createdAt"]):
            findings["receipt"] = "receipt payloadHash %s written %s, approved %s at %s" % (str(opening(receipts[0])["criteria"].get("payloadHash"))[:23], receipts[0]["entries"][0]["createdAt"], str(ev.get("payloadHash"))[:23], v["createdAt"])
    elif receipts or c.get("receipt"):
        findings["receipt"] = "a receipt names a release that was not accepted"
    return outcome


manifest_path = os.path.join(AUD, "case-manifest.json")
if not os.path.exists(manifest_path):
    print("NOT RUN: %s is missing" % manifest_path)
    sys.exit(2)
M = json.load(open(manifest_path))
SIGNERS = M.get("signers", {})
R = {}
for f in glob.glob(os.path.join(AUD, "*.audit-export.json")):
    d = json.load(open(f))
    R[d["recordId"]] = d
if not R:
    print("NOT RUN: no audit exports in %s" % AUD)
    sys.exit(2)

WRONG = 0
RESULT = {}   # case name -> (flow, probe, findings, verdict outcome)
for name, c in M["cases"].items():
    findings = {}
    outcome = (complaint if c["flow"] == "complaint" else release)(c, findings)
    probe = c.get("probe")
    want = PROBES.get(probe, set())
    ok = set(findings) == want
    WRONG += not ok
    RESULT[name] = (c["flow"], probe, findings, outcome)
    if probe:
        head = "caught" if ok else "NOT CAUGHT as expected (want exactly: %s)" % ", ".join(sorted(want))
        print("[%s] case %s (%s, probe %s): %s" % ("OK " if ok else "FAIL", name, c["flow"], probe, head))
    else:
        print("[%s] case %s (%s, verdict %s): %s" % ("OK " if ok else "FAIL", name, c["flow"], outcome or "none yet", "holds" if ok else "does not hold"))
    for k, v in sorted(findings.items()):
        print("       %-9s %s" % (k, v))

# OQ log: an assertion holds when at least one case exercises it and every such case agrees
clean = {n: r for n, r in RESULT.items() if not r[1]}
caught = lambda probe, finding: any(r[1] == probe and finding in r[2] for r in RESULT.values())  # noqa: E731


def holds(flow, finding, need=lambda r: True):
    rs = [r for r in clean.values() if r[0] == flow and need(r)]
    return bool(rs) and all(finding not in r[2] and "evidence" not in r[2] for r in rs)


accepted, ruled = (lambda r: r[3] == "accept"), (lambda r: r[3] is not None)
LINES = [
    ("GXP-06", "the digest on the close-out equals the digest re-derived from the stamps the reads listed", holds("complaint", "stamps", accepted)),
    ("GXP-06", "the close-out's evidenceRecordIds equals the set of the case's read children", holds("complaint", "children", accepted)),
    ("GXP-07", "the audit export's OUTCOME_REPORTED entry carries the signature meaning verbatim and names the completion it signs", holds("complaint", "signature", ruled)),
    ("GXP-07", "the entry's reporter is the QA investigator's identity, not an org admin's", holds("complaint", "reporter", ruled)),
    ("GXP-09", "the release's proposalHash, product, lot and quantity equal the proposal record's, and the check names the same proposal (cross-record check)", holds("release", "proposal")),
    ("GXP-10", "a check child whose performer is the proposer itself is caught by the cross-record check (the engine admits it)", caught("proposer-is-checker", "checker")),
    ("GXP-10", "the check's performer, and the agent that completed it, is the checker the release names (cross-record check)", holds("release", "checker", accepted)),
    ("GXP-10", "the child's controlPlanRef and controlPlanHash equal the release's (cross-record check)", holds("release", "plan")),
    ("GXP-11", "a release completed with no check child, or with a check child cancelled before work, is caught by the cross-record check (the engine admits it)",
     caught("no-check-child", "checkRef") and caught("check-cancelled", "checkRef")),
    ("GXP-11", "the release completion's checkRef names a FULFILLED child of the release (cross-record check)", holds("release", "checkRef", accepted)),
    ("GXP-13", "a revision requested on the rejected release appears on its chain", caught("revision-after-failed-check", "revision")),
    ("GXP-15", "the audit export's OUTCOME_REPORTED entry carries the signature meaning and names the completion it signs", holds("release", "signature", ruled)),
    ("GXP-19", "a release completed on a check older than the release allows is caught by the cross-record check (the engine admits it)", caught("stale-check", "age")),
    ("GXP-19", "the check was within the allowed age when the release was completed, signed and written (cross-record check)", holds("release", "age", accepted)),
    ("GXP-15", "the entry's reporter is the QA release signer's identity, not an org admin's", holds("release", "reporter", ruled)),
]
log_path = os.path.join(AUD, "oq.log")
have = set(open(log_path).read().splitlines()) if os.path.exists(log_path) else set()
new = ["%s\t%s" % (req, text) for req, text, ok in LINES if ok and "%s\t%s" % (req, text) not in have]
if new:
    with open(log_path, "a") as f:
        f.write("\n".join(new) + "\n")

print("\ncrosscheck: %s (%d case(s) not as expected; %d assertion(s) added to %s)" % ("PASS" if WRONG == 0 else "FAIL", WRONG, len(new), log_path))
sys.exit(0 if WRONG == 0 else 1)
