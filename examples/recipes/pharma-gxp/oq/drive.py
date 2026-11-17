#!/usr/bin/env python3
"""Drive both workflows against your AGLedger Server and the system of record, and save the
bundle `crosscheck.py` reads.

Nine cases. Four are the workflows as the recipe means them:

  A  complaint, read-only: QA opens the case, the orchestrator delegates four reads, each
     reader signs its own evidence, the close-out is refused while a read is open and
     admitted once all are terminal, QA accepts with a signature meaning.
  B  complaint with a reader that wrote: that read settles FAILED, the case is held by
     rollup, QA's accept is refused and the reject lands.
  C  release on a passed component lot: proposal, release opened from the control plan,
     check delegated to the checker, release completion refused while the check is open,
     check FULFILLED, payload hash bound, QA accepts, the writer refuses an altered
     payload, creates the batch record from the approved one and notarizes the receipt.
  D  release on a failed component lot: the check settles FAILED, the release is held, QA
     can only reject, the writer refuses, nothing is written.

Five are things the engine admits and the cross-record check has to catch. E to H stop at
the proposer's completion, where QA would be asked to sign, and are then rejected:

  E  a release completed with no check child (its checkRef names case C's check)
  F  a release whose check child the proposer cancelled before it was activated
  G  a release whose check child the proposer performed itself
  H  a release rejected over a failed check, then sent back for revision

  I  a release that allows a check one minute old, completed and accepted after the check
     passed that age (the run waits 65 seconds): the writer refuses to write

Every assertion is one of the `oqAsserts` lines in `validation/REQUIREMENTS.json`. Those
that hold are appended to the OQ log as `<requirement id><TAB><assertion>`, the format
`validation/build-matrix.py` reads. `crosscheck.py` appends its own lines to the same log.

    python3 oq/drive.py [--out oq-bundle]

Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (an admin key: it provisions one agent per role,
mints the writer's read-only key and runs the complaint-history search), ODOO_URL, ODOO_DB, ODOO_LOGIN, ODOO_PASSWORD (defaults
match sor/setup.sh). Needs the types registered (register.sh) and the system of record up
(sor/setup.sh); it runs sor/seed-sor.py itself. Run it against a test install: it creates
agents, records and one manufacturing order per run. Exit 0 iff every assertion holds, 2
when a prerequisite is missing.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RECIPE = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(RECIPE, "sor"))
from oqlib import Ledger, Claims, mk_agent as new_agent, admin_org, require_types, admitted, now  # noqa: E402
from odoo import Odoo, sha256, stamp_digest  # noqa: E402
import checker as precheck  # noqa: E402
import readers as rd  # noqa: E402
import writer as wr  # noqa: E402

ap = argparse.ArgumentParser(description="Drive the pharma-gxp OQ cases and save the bundle.")
ap.add_argument("--out", default="oq-bundle", help="bundle directory (emptied first)")
ARGS = ap.parse_args()
OUT = os.path.abspath(ARGS.out)

PRODUCT = "API-INTERMEDIATE-7"
TYPES = {"case": "calder-complaint-case-v1", "read": "calder-evidence-read-v1", "proposal": "calder-batch-record-proposal-v1",
         "release": "calder-batch-record-release-v1", "check": "calder-precondition-check-v1", "receipt": "calder-sor-write-receipt-v1"}

L = Ledger()
RUN = str(int(time.time()))[-6:]
C = Claims(RECIPE)
claim, expect = C.claim, C.expect
MANIFEST = {"run": RUN, "cases": {}}
COMPLETIONS = {"_byRecord": {}}          # evidence bodies by completion id: an export carries only their hash


def mk_agent(name):
    return new_agent(L, ORG, "%s-%s" % (name, RUN))


def record(rid):
    return L.get("/v1/records/%s" % rid)[1]


def status(rid):
    return record(rid).get("status")


def create(key, body):
    s, b = L.post("/v1/records", body, key=key)
    if s != 201:
        print("    create answered %s: %s" % (s, json.dumps(b)[:400]))
    return s, b


def one_shot():
    """Terms for every gated child: one submission and a deadline, so a failure is final and rolls up."""
    return {"maxSubmissions": 1, "deadline": now(hours=4)}


def handshake(rid, principal, performer):
    """propose (principal), accept (performer), activate (principal): the performer's consent on the chain."""
    return (L.post("/v1/records/%s/transition" % rid, {"action": "propose"}, key=principal["key"])[0],
            L.post("/v1/records/%s/accept" % rid, {}, key=performer["key"])[0],
            L.post("/v1/records/%s/transition" % rid, {"action": "activate"}, key=principal["key"])[0])


def complete(rid, key, evidence):
    s, b = L.post("/v1/records/%s/completions" % rid, {"evidence": evidence}, key=key)
    if s == 201 and b.get("id"):
        COMPLETIONS[b["id"]] = evidence
        COMPLETIONS["_byRecord"][rid] = b["id"]
    return s, b


def verdict(rid, signer, completion_id, decision, meaning, role, name, regulation, notes):
    checks = {"signatureMeaning": meaning, "signerRole": role, "signerName": name, "regulation": regulation, "signedAt": now()}
    return L.post("/v1/records/%s/verdict" % rid, {"verdict": decision, "completionId": completion_id, "checks": checks, "notes": notes}, key=signer["key"])


def wait_rollup(rid, seconds=45):
    """The cascade rollup is asynchronous: poll until the parent leaves ACTIVE."""
    for _ in range(seconds):
        r = record(rid)
        if r.get("status") != "ACTIVE":
            return r
        time.sleep(1)
    return record(rid)


def ledger_history(product_code):
    """The complaint-history search. An agent key's search is scoped to its own records, so this is the admin key's."""
    s, b = L.get("/v1/records/search", params={"type": TYPES["case"], "criteria[productCode]": product_code, "limit": 100})
    return [{"id": r["id"], "createdAt": r.get("createdAt"), "status": r.get("status")} for r in b.get("data", [])]


# ----------------------------------------------------------------------------- prerequisites
ORG = admin_org(L)
require_types(L, TYPES.values())
try:
    Odoo()
except Exception as e:  # noqa: BLE001
    print("NOT RUN: the system of record is not reachable (%s); run sor/setup.sh" % e)
    sys.exit(2)
seeded = subprocess.run([sys.executable, os.path.join(RECIPE, "sor", "seed-sor.py")], capture_output=True, text=True)
if seeded.returncode != 0:
    print("NOT RUN: sor/seed-sor.py failed: %s" % seeded.stderr.strip()[-400:])
    sys.exit(2)
SEED = json.loads(seeded.stdout)
PLAN_REF, BOM_REF = "qc.test/%d" % SEED["controlPlan"], "mrp.bom/%d" % SEED["bom"]

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".json") or f == "oq.log":
        os.remove(os.path.join(OUT, f))
json.dump(L.get("/v1/verification-keys")[1], open(os.path.join(OUT, "verification-keys.json"), "w"))
VERSION = L.get("/health/ready")[1].get("version")

print("== run %s against %s (Server %s) ==" % (RUN, L.base, VERSION))
QA_INV = mk_agent("calder-qa-investigator")       # a person: principal of the complaint case
ORCH = mk_agent("calder-case-orchestrator")       # automation: performer of the case, delegates the reads
READERS = {src: mk_agent("calder-%s-reader" % src) for src in ("mes", "lims", "distribution", "complaint-history")}
QA_REL = mk_agent("calder-qa-release")            # a person: principal of the release
PROP = mk_agent("calder-batch-proposer")          # automation: performer of the release, delegates the check
CHECKER = mk_agent("calder-precondition-checker")
WRITER = mk_agent("calder-erp-writer")
# The writer is a party to no release, and an agent key reads only its own records: it re-reads the release
# through a read-only key (admin-observer: records and completions, no action).
s, k = L.post("/v1/admin/api-keys", {"ownerId": ORG, "ownerType": "org", "role": "admin", "scopeProfile": "admin-observer"})
if s != 201:
    raise SystemExit("could not mint the writer's read-only key: %s %s" % (s, json.dumps(k)[:300]))
WRITER_READ_KEY = k["apiKey"]


def writer_read(path):
    return L.get(path, key=WRITER_READ_KEY)


def writer_refuses(payload, rel):
    """The writer raises Refused, having issued no write, and no order names the release in the system of record."""
    o = Odoo()
    try:
        wr.write(o, payload, rel, writer_read)
    except wr.Refused as e:
        print("    writer: %s" % e)
        return (o.writes, len(o.search_read("mrp.production", [["origin", "ilike", rel]], ["id"]))) == (0, 0)
    return False


MANIFEST["server"] = {"url": L.base, "version": VERSION}


# ----------------------------------------------------------------------------- complaint flow
def complaint_case(case_id, lots, mutate_in=None):
    complaint = "CMP-%s-%s" % (RUN, case_id)
    print("\n== CASE %s: complaint %s on %s (%s) ==" % (case_id, complaint, ",".join(lots), "the %s reader writes" % mutate_in if mutate_in else "read-only"))
    crit = {"complaintId": complaint, "productCode": PRODUCT, "lotNumbers": lots, "receivedAt": now(),
            "complaintCategory": "particulate", "complaintSource": "customer",
            "descriptionHash": sha256("Visible particulate reported in a vial from lot %s" % lots[0]),
            "distributed": False, "readOnly": True, "openedBy": "QA Investigator"}
    s, b = create(QA_INV["key"], {"type": TYPES["case"], "principalAgentId": QA_INV["id"], "performerAgentId": ORCH["id"],
                                  "gateMode": "principal", "criteria": crit, "correlationId": complaint})
    opened = (s, b.get("principalAgentId")) == (201, QA_INV["id"])
    case = b["id"]
    codes = handshake(case, QA_INV, ORCH)
    active = status(case)
    if not mutate_in:
        claim("GXP-01", "QA opens the case as principal and the record is created", opened, True)
        claim("GXP-01", "the orchestrator's accept lands on the chain before activation", codes, (200, 200, 200))
        claim("GXP-01", "the case reads ACTIVE", active, "ACTIVE")
    else:
        expect("case opened, accepted and ACTIVE", (opened, codes, active), (True, (200, 200, 200), "ACTIVE"))

    scopes = {"mes": "manufacturing order and consumed lots for %s" % lots[0], "lims": "inspections on the lot, its order and its component lots",
              "distribution": "outbound movements of the lot", "complaint-history": "prior complaint cases for the product on the ledger"}
    children = []
    for src, reader in READERS.items():
        s, b = create(ORCH["key"], {"type": TYPES["read"], "parentRecordId": case, "performerAgentId": reader["id"], "autoActivate": True, **one_shot(),
                                    "criteria": {"caseRef": case, "sourceSystem": src, "readScope": scopes[src], "readOnly": True}})
        claim("GXP-02", "the orchestrator delegates each read as a child with autoActivate", s, 201)
        claim("GXP-02", "each child reads ACTIVE with the orchestrator as its principal and the reader as its performer",
              (b.get("status"), b.get("principalAgentId"), b.get("performerAgentId")), ("ACTIVE", ORCH["id"], reader["id"]))
        children.append((src, b["id"], reader))
    MANIFEST["cases"][case_id] = {"flow": "complaint", "case": case}

    premature = {"investigationPerformed": True, "evidenceRecordIds": [c[1] for c in children], "conclusion": "inconclusive",
                 "rootCauseCategory": "undetermined", "summaryHash": sha256("premature"), "capaRequired": False, "reportable": False,
                 "sorRecordsUnchanged": True, "sorWriteStampDigest": sha256("premature")}
    s, b = complete(case, ORCH["key"], premature)
    claim("GXP-04", "the case completion is refused 422 while reads are open", s, 422)
    claim("GXP-04", "the refusal names the open children", "child" in json.dumps(b).lower(), True)

    stamps_at_read = []
    for src, cid, reader in children:
        o = Odoo()  # one client per reader: `mutating` is computed from its own write counter
        if mutate_in == src:
            lot_id = o.search_read("stock.lot", [["name", "=", lots[0]]], ["id"], limit=1)[0]["id"]
            o.write("stock.lot", [lot_id], {})  # an empty write is still a write call against the system of record
        ev = rd.READERS[src](o, lots, PRODUCT, ledger=ledger_history)
        stamps_at_read += ev["sourceRecords"]
        s, b = complete(cid, reader["key"], ev)
        st = status(cid)
        if mutate_in == src:
            claim("GXP-03", "a read completion with mutating true settles FAILED", (admitted(s, b), st), (True, "FAILED"))
        else:
            expect("%s read signed by its reader settles FULFILLED" % src, (admitted(s, b), st), (True, "FULFILLED"))

    if mutate_in:
        rec = wait_rollup(case)
        claim("GXP-03", "the case is held by rollup after a mutating one-shot read", rec.get("status"), ["PROCESSING", "FAILED"])
        held = rec.get("latestCompletionId")
        s, b = verdict(case, QA_INV, held, "accept", "approved", "qa-investigator", "QA Investigator", "21 CFR 211.198", "attempting approval of a case whose read wrote")
        claim("GXP-03", "QA accept is refused 422 on the rolled-up failure", s, 422)
        s, b = verdict(case, QA_INV, held, "reject", "rejected", "qa-investigator", "QA Investigator", "21 CFR 211.198",
                       "A reader wrote to the system of record. The case is not read-only and is rejected.")
        claim("GXP-03", "the QA reject verdict lands and the case reads FAILED", (s, b.get("recordStatus")), (200, "FAILED"))
        MANIFEST["cases"][case_id]["verdict"] = "reject"
        return

    # close-out: re-read every stamp the reads listed and bind the digest
    o = Odoo()
    by_model = {}
    for st_ in stamps_at_read:
        if st_["model"] != "agledger.record":
            by_model.setdefault(st_["model"], set()).add(int(st_["id"]))
    stamps_now = [s_ for m, ids in by_model.items() for s_ in o.stamps(m, sorted(ids))]
    stamps_now += [s_ for s_ in stamps_at_read if s_["model"] == "agledger.record"]  # the ledger is append-only
    unchanged = stamp_digest(stamps_now) == stamp_digest(stamps_at_read)
    expect("source write stamps unchanged between read and close", unchanged, True)
    ev = {"investigationPerformed": True, "evidenceRecordIds": [c[1] for c in children], "conclusion": "not-confirmed",
          "rootCauseCategory": "undetermined", "summaryHash": sha256("summary-%s" % complaint), "capaRequired": False, "reportable": False,
          "sorRecordsUnchanged": unchanged, "sorWriteStampDigest": stamp_digest(stamps_now)}
    s, b = complete(case, ORCH["key"], ev)
    claim("GXP-04", "the case completion is admitted once every read is terminal", (admitted(s, b), status(case)), (True, "PROCESSING"))
    s, v = verdict(case, QA_INV, b.get("id"), "accept", "approved", "qa-investigator", "QA Investigator", "21 CFR 211.198",
                   "Investigation reviewed. Evidence complete, no system of record written. Approved for closure.")
    claim("GXP-07", "QA accept with a signature meaning settles the case FULFILLED", (s, v.get("recordStatus")), (200, "FULFILLED"))
    MANIFEST["cases"][case_id]["verdict"] = "accept"

    # a write to a record the reads listed moves its stamp, and the digest re-derived from the system no longer equals the bound one
    lot_id = o.search_read("stock.lot", [["name", "=", lots[0]]], ["id"], limit=1)[0]["id"]
    time.sleep(1.1)  # write_date has one-second resolution
    o.write("stock.lot", [lot_id], {})
    moved = [s_ for m, ids in by_model.items() for s_ in o.stamps(m, sorted(ids))] + [s_ for s_ in stamps_at_read if s_["model"] == "agledger.record"]
    claim("GXP-06", "a stamp moved between read and close changes the re-derived digest", stamp_digest(moved) != ev["sorWriteStampDigest"], True)


# ----------------------------------------------------------------------------- release flow
def open_release(case_id, proposed_lot, component_lot, clean, max_age=60):
    """Proposal and release, to the point where the proposer would delegate the check. `clean` is whether this
    case's assertions go to the OQ log (cases C and D) or are only steps the case depends on (the probes)."""
    proposal = {"productCode": PRODUCT, "bomRef": BOM_REF, "quantity": 10, "proposedLot": proposed_lot,
                "componentLots": [{"productCode": "SOLVENT-A", "lotName": component_lot, "quantity": 20}], "line": "LINE-3",
                "proposalHash": sha256("proposal-%s" % proposed_lot), "producedBy": {"kind": "rule-based"},
                "rationale": "Campaign slot available on LINE-3; component lot on hand per inventory."}
    s, b = create(PROP["key"], {"type": TYPES["proposal"], "principalAgentId": PROP["id"], "criteria": proposal, "correlationId": proposed_lot})
    prop_id = b["id"]
    notarized = (s, b.get("status")) == (201, "RECORDED")
    required, plan_hash = precheck.read_control_plan(Odoo(), PLAN_REF)  # QA's read of the control plan in the quality system
    crit = {"proposalRef": prop_id, "proposalHash": proposal["proposalHash"], "productCode": PRODUCT, "lotNumber": proposed_lot, "quantity": 10,
            "requiredChecks": required, "controlPlanRef": PLAN_REF, "controlPlanHash": plan_hash,
            "checkerAgentId": CHECKER["id"], "maxCheckAgeMinutes": max_age, "requestedBy": "QA Release"}
    s, b = create(QA_REL["key"], {"type": TYPES["release"], "principalAgentId": QA_REL["id"], "performerAgentId": PROP["id"],
                                  "gateMode": "principal", "criteria": crit, "correlationId": proposed_lot})
    rel = b["id"]
    opened = (s, b.get("principalAgentId"), b.get("criteria", {}).get("controlPlanHash")) == (201, QA_REL["id"], plan_hash)
    codes = handshake(rel, QA_REL, PROP)
    if clean:
        claim("GXP-08", "the proposer notarizes the proposal and it reads RECORDED", notarized, True)
        claim("GXP-09", "QA opens the release as principal with the control plan bound", opened, True)
        claim("GXP-09", "the proposer's accept lands on the chain before activation", codes, (200, 200, 200))
    else:
        expect("proposal notarized, release opened and ACTIVE", (notarized, opened, codes), (True, True, (200, 200, 200)))
    payload = wr.build_payload(Odoo(), proposal)
    MANIFEST["cases"][case_id] = {"flow": "release", "proposal": prop_id, "release": rel}
    return proposal, prop_id, rel, plan_hash, payload


def delegate_check(rel, prop_id, plan_hash, performer, activate=True):
    """The child carries the plan's hash and a pointer to it, never the list."""
    return create(PROP["key"], {"type": TYPES["check"], "parentRecordId": rel, "performerAgentId": performer["id"], "autoActivate": activate, **one_shot(),
                                "criteria": {"proposalRef": prop_id, "productCode": PRODUCT, "controlPlanRef": PLAN_REF, "controlPlanHash": plan_hash}})


def release_evidence(check_id, proposed_lot, payload):
    return {"checkRef": check_id, "checkOutcome": "FULFILLED", "sorModel": "mrp.production", "lotNumber": proposed_lot,
            "quantity": 10, "payloadHash": wr.payload_hash(payload)}


def batch_release(case_id, proposed_lot, component_lot, revise=False):
    """Cases C and D, and H when `revise` (D, then a revision requested on the rejected release)."""
    print("\n== CASE %s: batch record %s from %s%s ==" % (case_id, proposed_lot, component_lot, ", then a revision is requested" if revise else ""))
    proposal, prop_id, rel, plan_hash, payload = open_release(case_id, proposed_lot, component_lot, clean=not revise)
    s, b = delegate_check(rel, prop_id, plan_hash, CHECKER)
    check_id = b["id"]
    rel_ev = release_evidence(check_id, proposed_lot, payload)
    s2, b2 = complete(rel, PROP["key"], rel_ev)
    if not revise:
        claim("GXP-10", "the proposer delegates the check to the checker as a child",
              (s, b.get("status"), b.get("performerAgentId"), b.get("parentRecordId")), (201, "ACTIVE", CHECKER["id"], rel))
        claim("GXP-11", "the release completion is refused 422 while the check is open", s2, 422)

    oc = Odoo()
    ev = precheck.run(oc, proposal, PLAN_REF)
    s, b = complete(check_id, CHECKER["key"], ev)
    st = status(check_id)
    if ev["failedChecks"]:
        rec = wait_rollup(rel)
        s2, b2 = complete(rel, PROP["key"], rel_ev)
        held = rec.get("latestCompletionId")
        s3, _ = verdict(rel, QA_REL, held, "accept", "approved", "qa-release", "QA Release", "21 CFR 11.50", "attempting approval over a failed check")
        s4, b4 = verdict(rel, QA_REL, held, "reject", "rejected", "qa-release", "QA Release", "21 CFR 11.50",
                         "Precondition check failed: %s. Batch record not created." % ", ".join(ev["failedChecks"]))
        prod = oc.search_read("product.product", [["default_code", "=", PRODUCT]], ["id"], limit=1)[0]["id"]
        lots = oc.search_read("stock.lot", [["name", "=", proposed_lot], ["product_id", "=", prod]], ["id"])
        orders = oc.search_read("mrp.production", [["origin", "ilike", rel]], ["id"])
        if not revise:
            claim("GXP-12", "one failed check settles FAILED", (admitted(s, b), st, ev["failedChecks"]), (True, "FAILED", ["component-lots-inspected"]))
            claim("GXP-13", "the release is held by rollup after the failed one-shot check", rec.get("status"), ["PROCESSING", "FAILED"])
            claim("GXP-11", "the release completion is still refused after a failed check", s2, [422, 409])
            claim("GXP-13", "QA accept is refused 422 on the rolled-up failure", s3, 422)
            claim("GXP-13", "the QA reject verdict lands and the release reads FAILED", (s4, b4.get("recordStatus")), (200, "FAILED"))
            claim("GXP-13", "no manufacturing order or lot exists in the system of record for the proposed lot", (len(lots), len(orders)), (0, 0))
            claim("GXP-19", "the writer refuses to write for a release that is not FULFILLED", writer_refuses(payload, rel), True)
        else:
            expect("failed check, release rejected by QA, nothing written", (st, s4, b4.get("recordStatus"), len(lots), len(orders)), ("FAILED", 200, "FAILED", 0, 0))
            s5, b5 = L.post("/v1/records/%s/revision" % rel, {"reason": "OQ probe: a revision requested on a release rejected over a failed check"}, key=QA_REL["key"])
            expect("the engine admits a revision request on the rejected release", s5, [200, 201])
            if s5 not in (200, 201):
                print("    revision answered %s: %s" % (s5, json.dumps(b5)[:300]))
            MANIFEST["cases"][case_id]["probe"] = "revision-after-failed-check"
        MANIFEST["cases"][case_id]["verdict"] = "reject"
        return check_id

    claim("GXP-12", "every required check passed settles FULFILLED", (admitted(s, b), st), (True, "FULFILLED"))
    s, b = complete(rel, PROP["key"], rel_ev)
    claim("GXP-14", "the release completion is admitted once the check is FULFILLED, with the payload hash bound", (admitted(s, b), status(rel)), (True, "PROCESSING"))
    s, v = verdict(rel, QA_REL, b.get("id"), "accept", "approved", "qa-release", "QA Release", "21 CFR 11.50",
                   "Reviewed the precondition check %s. Approved: the batch record may be created." % check_id)
    claim("GXP-15", "QA accept with a Part 11 signature meaning settles the release FULFILLED", (s, v.get("recordStatus")), (200, "FULFILLED"))
    claim("GXP-19", "the writer refuses a payload whose hash is not the one QA approved", writer_refuses(dict(payload, product_qty=payload["product_qty"] + 1), rel), True)
    ow = Odoo()
    receipt = wr.write(ow, payload, rel, writer_read)  # re-reads the release first, then sends exactly the payload whose hash QA approved
    s, b = create(WRITER["key"], {"type": TYPES["receipt"], "principalAgentId": WRITER["id"], "criteria": receipt, "correlationId": proposed_lot})
    claim("GXP-16", "the writer notarizes the receipt and it reads RECORDED, with the same payload hash as the release completion",
          (s, b.get("status"), receipt["payloadHash"]), (201, "RECORDED", rel_ev["payloadHash"]))
    row = ow.read("mrp.production", [int(receipt["sorRecordId"])], ["lot_producing_id"])[0]
    claim("GXP-16", "the manufacturing order exists in the system of record with the approved lot", row["lot_producing_id"] and row["lot_producing_id"][1], proposed_lot)
    MANIFEST["cases"][case_id].update({"verdict": "accept", "receipt": b["id"]})
    return check_id


def probe_release(case_id, proposed_lot, probe, borrowed_check=None):
    """Cases E, F and G: the proposer gets a release to QA's desk without an honest check. The engine admits each."""
    print("\n== CASE %s: probe, %s ==" % (case_id, probe))
    proposal, prop_id, rel, plan_hash, payload = open_release(case_id, proposed_lot, "SOLV-2026-0142", clean=False)
    if probe == "no-check-child":
        check_id = borrowed_check
    elif probe == "check-cancelled":
        # Cancelled before it was activated, a child is neutral to the rollup and the release takes its own
        # completion. Cancelled after (autoActivate, or the checker's accept), it fails the release by rollup.
        s, b = delegate_check(rel, prop_id, plan_hash, CHECKER, activate=False)
        check_id = b["id"]
        s, b = L.post("/v1/records/%s/cancel" % check_id, {"reason": "OQ probe: cancelled before the checker worked"}, key=PROP["key"])
        expect("the proposer cancels the check child before it is activated", (s, status(check_id)), (200, "CANCELLED"))
    else:  # proposer-is-checker
        s, b = delegate_check(rel, prop_id, plan_hash, PROP)
        check_id = b["id"]
        s, b = complete(check_id, PROP["key"], precheck.run(Odoo(), proposal, PLAN_REF))
        expect("the proposer performs the check itself and it settles FULFILLED", (admitted(s, b), status(check_id)), (True, "FULFILLED"))
    s, b = complete(rel, PROP["key"], release_evidence(check_id, proposed_lot, payload))
    expect("the engine admits the release completion", (admitted(s, b), status(rel)), (True, "PROCESSING"))
    if not admitted(s, b):
        print("    completion answered %s: %s" % (s, json.dumps(b)[:300]))
    s, v = verdict(rel, QA_REL, b.get("id"), "reject", "rejected", "qa-release", "QA Release", "21 CFR 11.50", "OQ probe (%s): the cross-record check does not hold." % probe)
    expect("QA rejects the release", (s, v.get("recordStatus")), (200, "FAILED"))
    MANIFEST["cases"][case_id].update({"verdict": "reject", "probe": probe})


def stale_release(case_id, proposed_lot):
    """Case I: the check is honest and passes, and is older than the release allows by the time it is relied on."""
    print("\n== CASE %s: probe, stale-check ==" % case_id)
    proposal, prop_id, rel, plan_hash, payload = open_release(case_id, proposed_lot, "SOLV-2026-0142", clean=False, max_age=1)
    s, b = delegate_check(rel, prop_id, plan_hash, CHECKER)
    check_id = b["id"]
    s, b = complete(check_id, CHECKER["key"], precheck.run(Odoo(), proposal, PLAN_REF))
    expect("the check settles FULFILLED", (admitted(s, b), status(check_id)), (True, "FULFILLED"))
    print("    waiting 65 seconds: the release allows a check one minute old")
    time.sleep(65)
    s, b = complete(rel, PROP["key"], release_evidence(check_id, proposed_lot, payload))
    expect("the engine admits the release completion on the stale check", (admitted(s, b), status(rel)), (True, "PROCESSING"))
    s, v = verdict(rel, QA_REL, b.get("id"), "accept", "approved", "qa-release", "QA Release", "21 CFR 11.50", "OQ probe (stale-check): approved without the cross-record check.")
    expect("the engine admits QA's accept", (s, v.get("recordStatus")), (200, "FULFILLED"))
    claim("GXP-19", "the writer refuses to write when the check is older than the release allows", writer_refuses(payload, rel), True)
    MANIFEST["cases"][case_id].update({"verdict": "accept", "probe": "stale-check"})


# ----------------------------------------------------------------------------- run
complaint_case("A", ["BATCH-2026-0917"])
complaint_case("B", ["BATCH-2026-0917"], mutate_in="distribution")
check_c = batch_release("C", "BATCH-2026-%s1" % RUN[-3:], "SOLV-2026-0142")
batch_release("D", "BATCH-2026-%s2" % RUN[-3:], "SOLV-2026-0177")
probe_release("E", "BATCH-2026-%s3" % RUN[-3:], "no-check-child", borrowed_check=check_c)
probe_release("F", "BATCH-2026-%s4" % RUN[-3:], "check-cancelled")
probe_release("G", "BATCH-2026-%s5" % RUN[-3:], "proposer-is-checker")
batch_release("H", "BATCH-2026-%s6" % RUN[-3:], "SOLV-2026-0177", revise=True)
stale_release("I", "BATCH-2026-%s7" % RUN[-3:])

print("\n== save the bundle ==")
exported = 0
for case_id, c in MANIFEST["cases"].items():
    root = c["case"] if c["flow"] == "complaint" else c["release"]
    # the children as the Server lists them, not as the orchestration remembers them
    s, b = L.get("/v1/records/%s/sub-records" % root, params={"limit": 100})
    c["children"] = [r["id"] for r in b.get("data", [])]
    for rid in [root] + c["children"] + [c[k] for k in ("proposal", "receipt") if c.get(k)]:
        s, b = L.get("/v1/records/%s/audit-export" % rid)
        expect("audit export of %s" % rid, s, 200)
        json.dump(b, open(os.path.join(OUT, "%s.audit-export.json" % rid), "w"))
        exported += 1
json.dump(MANIFEST, open(os.path.join(OUT, "case-manifest.json"), "w"), indent=1)
json.dump(COMPLETIONS, open(os.path.join(OUT, "completions.json"), "w"), indent=1)
C.append(os.path.join(OUT, "oq.log"))
print("  %d audit exports, case-manifest.json, completions.json, verification-keys.json and oq.log in %s" % (exported, OUT))
print("\ndrive: %s (%d failed)" % ("PASS" if C.failed == 0 else "FAIL", C.failed))
sys.exit(0 if C.failed == 0 else 1)
