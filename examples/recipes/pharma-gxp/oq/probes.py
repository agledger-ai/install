#!/usr/bin/env python3
"""The refusals the traceability matrix lists, probed against your AGLedger Server. No system
of record is needed: each probe sends a body the recipe's types or the engine must refuse.

  at create     a proposal by an LLM with no model, a release with no required checks, a
                check child that carries a list, a receipt with no payload hash or a
                reference that is not a record id
  at completion a close-out missing a conditional field, a release completion that claims
                a failed check or binds no payload hash (201 with structuralValidation
                INVALID: the record does not advance)
  at the gate   a precondition check with a short list, a renamed check or a stale plan
                hash settles FAILED
  delegation    only the release's performer can create the check child, and the release's
                principal cannot be named the checker

A refusal counts only when the Server's answer names what the probe violated.

    python3 oq/probes.py [bundle directory, default oq-bundle]

Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (an admin key). Needs the types registered. It
creates three agents and a handful of records per run, so run it against a test install.
Assertions that hold are appended to `oq.log` in the bundle. Exit 0 iff every probe is
refused, 2 when a prerequisite is missing.
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from oqlib import Ledger, Claims, mk_agent, admin_org, require_types, now  # noqa: E402

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "oq-bundle")
L = Ledger()
C = Claims(RECIPE)
RUN = str(int(time.time()))[-6:]
CASE_T, PROPOSAL_T, RELEASE_T, CHECK_T, RECEIPT_T = ("calder-complaint-case-v1", "calder-batch-record-proposal-v1",
                                                     "calder-batch-record-release-v1", "calder-precondition-check-v1", "calder-sor-write-receipt-v1")
ORG = admin_org(L)
require_types(L, [CASE_T, PROPOSAL_T, RELEASE_T, CHECK_T, RECEIPT_T])
QA = mk_agent(L, ORG, "calder-oq-qa-%s" % RUN)            # principal of the probe records
WORK = mk_agent(L, ORG, "calder-oq-performer-%s" % RUN)   # their performer: the orchestrator, the proposer
OTHER = mk_agent(L, ORG, "calder-oq-checker-%s" % RUN)    # a delegate
UUID = "00000000-0000-4000-8000-%012d"
SHA0 = "sha256:" + "0" * 64


def names(body, word):
    return word.lower() in json.dumps(body).lower()


def refused_at_create(req, text, key, body, word):
    s, b = L.post("/v1/records", body, key=key)
    C.claim(req, text, (400 <= s < 500, names(b, word)), (True, True), "(%s %s)" % (s, json.dumps(b)[:200]))


def principal_record(rtype, crit):
    """A principal-gated record, opened by QA, accepted by the performer and ACTIVE."""
    s, b = L.post("/v1/records", {"type": rtype, "principalAgentId": QA["id"], "performerAgentId": WORK["id"], "gateMode": "principal", "criteria": crit}, key=QA["key"])
    if s != 201:
        raise SystemExit("could not open a %s: %s %s" % (rtype, s, json.dumps(b)[:300]))
    L.post("/v1/records/%s/transition" % b["id"], {"action": "propose"}, key=QA["key"])
    L.post("/v1/records/%s/accept" % b["id"], {}, key=WORK["key"])
    L.post("/v1/records/%s/transition" % b["id"], {"action": "activate"}, key=QA["key"])
    return b["id"]


def refused_at_completion(req, text, rid, evidence, word):
    s, b = L.post("/v1/records/%s/completions" % rid, {"evidence": evidence}, key=WORK["key"])
    st = L.get("/v1/records/%s" % rid)[1].get("status")
    C.claim(req, text, (s, b.get("structuralValidation"), st == "ACTIVE", names(b, word)), (201, "INVALID", True, True), "(%s)" % json.dumps(b)[:200])


print("== refused at create ==")
proposal = {"productCode": "API-INTERMEDIATE-7", "bomRef": "mrp.bom/1", "quantity": 10, "proposedLot": "BATCH-2026-9%s" % RUN[-3:],
            "componentLots": [{"productCode": "SOLVENT-A", "lotName": "SOLV-2026-0142", "quantity": 20}], "line": "LINE-3",
            "proposalHash": SHA0, "producedBy": {"kind": "llm"}}
refused_at_create("GXP-08", "a proposal with producedBy.kind llm and no model is refused", WORK["key"],
                  {"type": PROPOSAL_T, "principalAgentId": WORK["id"], "criteria": proposal}, "model")
required = ["bom-active", "line-clear", "lot-number-unique"]
release = {"proposalRef": UUID % 2, "productCode": "API-INTERMEDIATE-7", "lotNumber": "BATCH-2026-9001", "quantity": 10,
           "requiredChecks": required, "controlPlanRef": "qc.test/1", "controlPlanHash": SHA0}
refused_at_create("GXP-09", "a release with empty requiredChecks is refused", QA["key"],
                  {"type": RELEASE_T, "principalAgentId": QA["id"], "performerAgentId": WORK["id"], "gateMode": "principal",
                   "criteria": dict(release, requiredChecks=[])}, "requiredChecks")
receipt = {"releaseRef": UUID % 3, "sorSystem": "odoo", "sorModel": "mrp.production", "sorRecordId": "7", "sorRecordName": "WH/MO/00007",
           "lotNumber": "BATCH-2026-9001", "payloadHash": SHA0, "writeDate": "2026-10-15 00:00:00", "writtenAt": now()}
refused_at_create("GXP-14", "a receipt without payloadHash is refused", WORK["key"],
                  {"type": RECEIPT_T, "principalAgentId": WORK["id"], "criteria": {k: v for k, v in receipt.items() if k != "payloadHash"}}, "payloadHash")
refused_at_create("GXP-16", "a receipt whose releaseRef is not a UUID is refused", WORK["key"],
                  {"type": RECEIPT_T, "principalAgentId": WORK["id"], "criteria": dict(receipt, releaseRef="WH/MO/00007")}, "releaseRef")

print("== refused at completion ==")
case = principal_record(CASE_T, {"complaintId": "CMP-OQ-%s" % RUN, "productCode": "API-INTERMEDIATE-7", "lotNumbers": ["BATCH-2026-0917"], "receivedAt": now(),
                                 "complaintCategory": "particulate", "complaintSource": "customer", "descriptionHash": SHA0, "distributed": False, "readOnly": True})
close = {"investigationPerformed": True, "evidenceRecordIds": [UUID % 4], "conclusion": "not-confirmed", "rootCauseCategory": "undetermined",
         "summaryHash": SHA0, "capaRequired": False, "reportable": False, "sorRecordsUnchanged": True, "sorWriteStampDigest": SHA0}
refused_at_completion("GXP-05", "a close-out with capaRequired true and no capaRef is refused", case, dict(close, capaRequired=True), "capaRef")
refused_at_completion("GXP-05", "a close-out with reportable true and no reportType or reportDueBy is refused", case, dict(close, reportable=True), "report")
refused_at_completion("GXP-05", "a close-out with no investigation and no written reason is refused (211.198(b)(3))", case, dict(close, investigationPerformed=False), "noInvestigationReason")
rel = principal_record(RELEASE_T, dict(release, lotNumber="BATCH-2026-9002"))
rel_ev = {"checkRef": UUID % 5, "checkOutcome": "FULFILLED", "sorModel": "mrp.production", "lotNumber": "BATCH-2026-9002", "quantity": 10, "payloadHash": SHA0}
refused_at_completion("GXP-14", "a release completion with checkOutcome FAILED is refused", rel, dict(rel_ev, checkOutcome="FAILED"), "checkOutcome")
refused_at_completion("GXP-14", "a release completion without payloadHash is refused", rel, {k: v for k, v in rel_ev.items() if k != "payloadHash"}, "payloadHash")

print("== the precondition gate ==")
# A failed one-shot child rolls its parent out of ACTIVE, and a parent that is not ACTIVE takes no more children:
# every child is created first, then the completions are submitted.
rel2 = principal_record(RELEASE_T, dict(release, lotNumber="BATCH-2026-9003"))
check_crit = {"proposalRef": UUID % 2, "productCode": "API-INTERMEDIATE-7", "controlPlanRef": "qc.test/1", "controlPlanHash": SHA0}
child = {"type": CHECK_T, "parentRecordId": rel2, "performerAgentId": OTHER["id"], "autoActivate": True, "maxSubmissions": 1, "deadline": now(hours=2)}
refused_at_create("GXP-10", "a check child whose criteria carries a list of checks is refused at create", WORK["key"],
                  dict(child, criteria=dict(check_crit, requiredChecks=required)), "requiredChecks")
kids = []
for _ in range(3):
    s, b = L.post("/v1/records", dict(child, criteria=check_crit), key=WORK["key"])
    if s != 201:
        raise SystemExit("could not delegate a check child: %s %s" % (s, json.dumps(b)[:300]))
    kids.append(b["id"])


def check_evidence(passed, plan_hash=SHA0):
    return {"requiredChecks": required, "controlPlanHash": plan_hash,
            "checks": [{"name": n, "sourceSystem": "odoo", "sourceRef": "n/a", "observed": "probe", "expected": "probe", "passed": True} for n in passed],
            "passedChecks": passed, "failedChecks": [], "checkedAt": now(), "checkerKind": "deterministic", "evidenceDigest": SHA0}


for rid, text, ev in ((kids[0], "a short passed list (fewer than the plan names) settles FAILED", check_evidence(required[:2])),
                      (kids[1], "the same count with one check renamed settles FAILED", check_evidence(required[:2] + ["something-else"])),
                      (kids[2], "a stale control plan hash settles FAILED", check_evidence(required, "sha256:" + "1" * 64))):
    s, b = L.post("/v1/records/%s/completions" % rid, {"evidence": ev}, key=OTHER["key"])
    C.claim("GXP-12", text, (s, b.get("structuralValidation") != "INVALID", L.get("/v1/records/%s" % rid)[1].get("status")), (201, True, "FAILED"), "(%s)" % json.dumps(b)[:200])

print("== delegation ==")
rel3 = principal_record(RELEASE_T, dict(release, lotNumber="BATCH-2026-9004"))
s, b = L.post("/v1/records", dict(child, parentRecordId=rel3, criteria=check_crit), key=OTHER["key"])
C.claim("GXP-17", "an agent that is not the release's performer cannot create the check child (binding of duty)", s, [403, 422], "(%s)" % json.dumps(b)[:200])
s, b = L.post("/v1/records", dict(child, parentRecordId=rel3, performerAgentId=QA["id"], criteria=check_crit), key=WORK["key"])
C.claim("GXP-17", "the release's principal (QA) cannot be named the checker (circular delegation)", s, [403, 422], "(%s)" % json.dumps(b)[:200])

os.makedirs(OUT, exist_ok=True)
added = C.append(os.path.join(OUT, "oq.log"))
print("\nprobes: %s (%d failed; %d assertion(s) added to %s)" % ("PASS" if C.failed == 0 else "FAIL", C.failed, added, os.path.join(OUT, "oq.log")))
sys.exit(0 if C.failed == 0 else 1)
