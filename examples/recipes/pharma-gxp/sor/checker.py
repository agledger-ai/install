#!/usr/bin/env python3
"""The deterministic precondition checker.

Not an LLM: a fixed set of checks, each a read against the system of record with a
stated expectation, run in the order the product's control plan lists them. The control
plan is read from the quality system (a qc.test whose questions are the check names) and
hashed, so the release record and the check record both bind the same plan.

    evidence = run(odoo, proposal, control_plan_ref)

returns the completion evidence for calder-precondition-check-v1. It never writes.

Checks implemented (add yours in CHECKS; a name the control plan lists that this module
does not implement is reported as failed, never skipped):
  bom-active                the referenced BOM exists, is active, and makes the product
  component-lots-on-hand    each component lot has at least the BOM-derived quantity in stock
  component-lots-inspected  each component lot has an incoming inspection in state success
  line-clear                no manufacturing order for the product is open (confirmed/progress/to_close)
  lot-number-unique         no lot of the product already carries the proposed lot number
"""
import datetime
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odoo import sha256, canon  # noqa: E402


def read_control_plan(o, ref):
    """ref is 'qc.test/<id>'. Returns (check names in sequence order, hash of the plan)."""
    model, _, tid = ref.partition("/")
    test = o.read(model, [int(tid)], ["name", "test_lines"])[0]
    lines = o.search_read("qc.test.question", [["id", "in", test["test_lines"]]], ["name", "type", "sequence"], order="sequence, id")
    names = [ln["name"] for ln in lines]
    digest = sha256(canon({"ref": ref, "name": test["name"], "questions": [[ln["name"], ln["type"]] for ln in lines]}))
    return names, digest


def _bom(o, proposal):
    model, _, bid = proposal["bomRef"].partition("/")
    rows = o.read(model, [int(bid)], ["active", "product_tmpl_id", "product_qty", "bom_line_ids"])
    return rows[0] if rows else None


def check_bom_active(o, p):
    b = _bom(o, p)
    prod = o.search_read("product.product", [["default_code", "=", p["productCode"]]], ["product_tmpl_id"], limit=1)
    ok = bool(b) and b["active"] and bool(prod) and b["product_tmpl_id"][0] == prod[0]["product_tmpl_id"][0]
    return ok, p["bomRef"], "active=%s product_tmpl=%s" % (b and b["active"], b and b["product_tmpl_id"]), "active BOM for %s" % p["productCode"]


def check_component_lots_on_hand(o, p):
    b = _bom(o, p)
    lines = o.read("mrp.bom.line", b["bom_line_ids"], ["product_id", "product_qty"]) if b else []
    need = {ln["product_id"][0]: ln["product_qty"] * p["quantity"] / (b["product_qty"] or 1.0) for ln in lines}
    refs, obs, ok = [], [], True
    for c in p["componentLots"]:
        prod = o.search_read("product.product", [["default_code", "=", c["productCode"]]], ["id"], limit=1)
        lot = o.search_read("stock.lot", [["name", "=", c["lotName"]], ["product_id", "=", prod[0]["id"]]], ["id"], limit=1) if prod else []
        q = o.search_read("stock.quant", [["lot_id", "=", lot[0]["id"]], ["location_id.usage", "=", "internal"]], ["quantity"]) if lot else []
        on_hand = sum(r["quantity"] for r in q)
        required = need.get(prod[0]["id"], c["quantity"]) if prod else c["quantity"]
        refs.append("stock.lot/%s" % (lot[0]["id"] if lot else "missing"))
        obs.append("%s on hand %.1f need %.1f" % (c["lotName"], on_hand, required))
        ok = ok and bool(lot) and on_hand >= required
    return ok, ",".join(refs), "; ".join(obs), "each component lot on hand >= BOM quantity"


def check_component_lots_inspected(o, p):
    refs, obs, ok = [], [], True
    for c in p["componentLots"]:
        prod = o.search_read("product.product", [["default_code", "=", c["productCode"]]], ["id"], limit=1)
        lot = o.search_read("stock.lot", [["name", "=", c["lotName"]], ["product_id", "=", prod[0]["id"]]], ["id"], limit=1) if prod else []
        ins = o.search_read("qc.inspection", [["object_id", "=", "stock.lot,%d" % lot[0]["id"]]], ["id", "name", "state"], order="id desc") if lot else []
        st = ins[0]["state"] if ins else "none"
        refs.append("qc.inspection/%s" % (ins[0]["id"] if ins else "missing"))
        obs.append("%s inspection %s" % (c["lotName"], st))
        ok = ok and st == "success"
    return ok, ",".join(refs), "; ".join(obs), "latest incoming inspection per component lot in state success"


def check_line_clear(o, p):
    prod = o.search_read("product.product", [["default_code", "=", p["productCode"]]], ["id"], limit=1)
    open_mo = o.search_read("mrp.production", [["product_id", "=", prod[0]["id"]], ["state", "in", ["confirmed", "progress", "to_close"]]], ["id", "name"]) if prod else []
    return not open_mo, "mrp.production", "open orders: %s" % ([m["name"] for m in open_mo] or "none"), "no open manufacturing order for the product"


def check_lot_number_unique(o, p):
    prod = o.search_read("product.product", [["default_code", "=", p["productCode"]]], ["id"], limit=1)
    dup = o.search_read("stock.lot", [["name", "=", p["proposedLot"]], ["product_id", "=", prod[0]["id"]]], ["id"]) if prod else []
    return not dup, "stock.lot", "existing lots named %s: %d" % (p["proposedLot"], len(dup)), "lot number not yet used for the product"


CHECKS = {
    "bom-active": check_bom_active,
    "component-lots-on-hand": check_component_lots_on_hand,
    "component-lots-inspected": check_component_lots_inspected,
    "line-clear": check_line_clear,
    "lot-number-unique": check_lot_number_unique,
}


def run(o, proposal, control_plan_ref, source_system="odoo"):
    writes_before = o.writes
    required, plan_hash = read_control_plan(o, control_plan_ref)
    results = []
    for name in required:
        fn = CHECKS.get(name)
        if fn is None:
            results.append({"name": name, "sourceSystem": source_system, "sourceRef": "n/a",
                            "observed": "check not implemented by this checker", "expected": "implemented", "passed": False})
            continue
        ok, ref, observed, expected = fn(o, proposal)
        results.append({"name": name, "sourceSystem": source_system, "sourceRef": ref[:200],
                        "observed": observed[:300], "expected": expected[:300], "passed": bool(ok)})
    if o.writes != writes_before:
        raise RuntimeError("checker issued a write; refusing to sign evidence")
    return {
        "requiredChecks": required,
        "controlPlanHash": plan_hash,
        "checks": results,
        "passedChecks": [r["name"] for r in results if r["passed"]],
        "failedChecks": [r["name"] for r in results if not r["passed"]],
        "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "checkerKind": "deterministic",
        "evidenceDigest": sha256(canon(results)),
    }


if __name__ == "__main__":
    import json
    from odoo import Odoo
    p = json.load(open(sys.argv[1]))
    print(json.dumps(run(Odoo(), p, sys.argv[2]), indent=1))
