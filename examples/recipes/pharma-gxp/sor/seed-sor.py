#!/usr/bin/env python3
"""Fixtures in the system of record for both flows. Idempotent.

Creates, or finds:
  products      SOLVENT-A (component) and API-INTERMEDIATE-7 (intermediate), both lot-tracked
  BOM           API-INTERMEDIATE-7 = 2 x SOLVENT-A
  solvent lots  SOLV-2026-0142 (incoming inspection passed) and SOLV-2026-0177 (failed), 100 each
  control plan  a qc.test whose questions are the precondition checks the release requires
  release test  a qc.test (assay 98..102) wired to the "production done" trigger for the intermediate
  history       one finished manufacturing order for lot BATCH-2026-0917 consuming SOLV-2026-0142,
                its auto-created release inspection filled (assay 99.4) and confirmed

Prints the ids as JSON on stdout for your orchestration (the control plan ref and the BOM ref).
"""
import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odoo import Odoo  # noqa: E402

CHECKS = ["bom-active", "component-lots-on-hand", "component-lots-inspected", "line-clear", "lot-number-unique"]
CONTROL_PLAN_NAME = "Batch record preconditions: API-INTERMEDIATE-7"
RELEASE_TEST_NAME = "API intermediate release assay"


def first(rows):
    return rows[0] if rows else None


def product(o, code):
    p = first(o.search_read("product.product", [["default_code", "=", code]], ["id", "product_tmpl_id"]))
    if p:
        return p
    pid = o.create("product.product", {"name": code, "default_code": code, "type": "consu",
                                       "is_storable": True, "tracking": "lot"})
    return o.read("product.product", [pid], ["id", "product_tmpl_id"])[0]


def lot(o, name, product_id, company):
    r = first(o.search_read("stock.lot", [["name", "=", name], ["product_id", "=", product_id]], ["id"]))
    return r["id"] if r else o.create("stock.lot", {"name": name, "product_id": product_id, "company_id": company})


def set_on_hand(o, product_id, lot_id, location, qty):
    ctx = {"inventory_mode": True}
    q = first(o.search_read("stock.quant", [["product_id", "=", product_id], ["lot_id", "=", lot_id], ["location_id", "=", location]], ["id", "quantity"]))
    if q and q["quantity"] >= qty:
        return q["id"]
    qid = q["id"] if q else o.create("stock.quant", {"product_id": product_id, "location_id": location, "lot_id": lot_id,
                                                      "inventory_quantity": qty}, ctx)
    if q:
        o.call("stock.quant", "write", [[qid], {"inventory_quantity": qty}], {"context": ctx})
    o.call("stock.quant", "action_apply_inventory", [[qid]], {"context": ctx})
    return qid


def qc_test(o, name, lines):
    t = first(o.search_read("qc.test", [["name", "=", name]], ["id"]))
    if t:
        return t["id"]
    uom = o.search_read("uom.uom", [["name", "in", ["Units", "Unit"]]], ["id"], limit=1)
    for ln in lines:
        if ln.get("type") == "quantitative" and uom:
            ln.setdefault("uom_id", uom[0]["id"])
    return o.create("qc.test", {"name": name, "test_lines": [[0, 0, ln] for ln in lines]})


def inspection_for(o, model, rid, test_id, product_id, qty, values):
    """One inspection on `model,rid`, driven to a terminal state from `values` (per line)."""
    ins = first(o.search_read("qc.inspection", [["object_id", "=", "%s,%d" % (model, rid)], ["test", "=", test_id]],
                              ["id", "state", "inspection_lines"], order="id desc"))
    if ins and ins["state"] in ("success", "failed") and ins["inspection_lines"]:
        return ins["id"], ins["state"]
    if ins and not ins["inspection_lines"]:
        # a bare create carries no lines, so its "success" is vacuous: cancel it and start again
        if ins["state"] not in ("canceled",):
            o.call("qc.inspection", "action_cancel", [[ins["id"]]])
        ins = None
    iid = ins["id"] if ins else o.create("qc.inspection", {"object_id": "%s,%d" % (model, rid), "product_id": product_id, "qty": qty})
    # populate the lines from the test through the same wizard the UI uses
    wiz = o.create("qc.inspection.set.test", {"test": test_id}, {"active_id": iid, "active_ids": [iid], "active_model": "qc.inspection"})
    o.call("qc.inspection.set.test", "action_create_test", [[wiz]], {"context": {"active_id": iid, "active_ids": [iid], "active_model": "qc.inspection"}})
    return drive_inspection(o, iid, values)


def drive_inspection(o, iid, values):
    st = o.read("qc.inspection", [iid], ["state", "inspection_lines"])[0]
    if st["state"] == "draft":
        o.call("qc.inspection", "action_todo", [[iid]])
    lines = o.read("qc.inspection.line", st["inspection_lines"], ["id", "name", "question_type", "uom_id"])
    uom = o.search_read("uom.uom", [["name", "in", ["Units", "Unit"]]], ["id"], limit=1)
    for ln in lines:
        v = values.get(ln["name"])
        if ln["question_type"] == "quantitative":
            vals = {"quantitative_value": v}
            if not ln.get("uom_id") and uom:
                vals["uom_id"] = uom[0]["id"]  # a test authored without a unit cannot be confirmed
            o.write("qc.inspection.line", [ln["id"]], vals)
        else:
            # qualitative: pick the answer value by name on the line's question
            opts = o.search_read("qc.test.question.value", [["name", "=", v]], ["id"])
            if opts:
                o.write("qc.inspection.line", [ln["id"]], {"qualitative_value": opts[0]["id"]})
    o.call("qc.inspection", "action_confirm", [[iid]])
    st = o.read("qc.inspection", [iid], ["state"])[0]["state"]
    if st == "waiting":
        o.call("qc.inspection", "action_approve", [[iid]])
        st = o.read("qc.inspection", [iid], ["state"])[0]["state"]
    return iid, st


def done_mo(o, inter, bom_id, solv, solv_lot, batch, company, qty=10.0):
    existing = first(o.search_read("stock.lot", [["name", "=", batch], ["product_id", "=", inter]], ["id"]))
    if existing:
        mo = first(o.search_read("mrp.production", [["lot_producing_id", "=", existing["id"]]], ["id", "name", "state"]))
        if mo and mo["state"] == "done":
            return mo["id"], existing["id"]
    mo = o.create("mrp.production", {"product_id": inter, "product_qty": qty, "bom_id": bom_id})
    o.call("mrp.production", "action_confirm", [[mo]])
    o.call("mrp.production", "action_assign", [[mo]])
    fin_lot = existing["id"] if existing else o.create("stock.lot", {"name": batch, "product_id": inter, "company_id": company})
    o.write("mrp.production", [mo], {"lot_producing_id": fin_lot, "qty_producing": qty})
    raw = o.read("mrp.production", [mo], ["move_raw_ids"])[0]["move_raw_ids"]
    o.write("stock.move", raw, {"picked": True})
    res = o.call("mrp.production", "button_mark_done", [[mo]])
    # resolve any confirmation wizard the button returns
    for _ in range(3):
        if not isinstance(res, dict) or not res.get("res_model"):
            break
        model, ctx = res["res_model"], dict(res.get("context") or {})
        wid = o.call(model, "create", [{}], {"context": ctx})
        meth = {"mrp.immediate.production": "process", "mrp.consumption.warning": "action_confirm",
                "mrp.production.backorder": "action_close_mo"}.get(model, "action_confirm")
        res = o.call(model, meth, [[wid]], {"context": ctx})
    return mo, fin_lot


def main():
    o = Odoo()
    company = o.call("res.company", "search", [[]], {"limit": 1})[0]
    wh = o.search_read("stock.warehouse", [], ["lot_stock_id"], limit=1)[0]
    stock_loc = wh["lot_stock_id"][0]
    solv = product(o, "SOLVENT-A")
    inter = product(o, "API-INTERMEDIATE-7")
    bom = first(o.search_read("mrp.bom", [["product_tmpl_id", "=", inter["product_tmpl_id"][0]]], ["id"]))
    bom_id = bom["id"] if bom else o.create("mrp.bom", {"product_tmpl_id": inter["product_tmpl_id"][0], "product_qty": 1.0,
                                                        "type": "normal", "bom_line_ids": [[0, 0, {"product_id": solv["id"], "product_qty": 2.0}]]})
    good_lot = lot(o, "SOLV-2026-0142", solv["id"], company)
    bad_lot = lot(o, "SOLV-2026-0177", solv["id"], company)
    set_on_hand(o, solv["id"], good_lot, stock_loc, 100.0)
    set_on_hand(o, solv["id"], bad_lot, stock_loc, 100.0)

    # incoming inspection per solvent lot: identity by HPLC, pass/fail
    incoming = qc_test(o, "SOLVENT-A incoming identity", [{"name": "Identity (HPLC retention match)", "type": "quantitative", "min_value": 0.98, "max_value": 1.02}])
    good_ins = inspection_for(o, "stock.lot", good_lot, incoming, solv["id"], 100.0, {"Identity (HPLC retention match)": 1.00})
    bad_ins = inspection_for(o, "stock.lot", bad_lot, incoming, solv["id"], 100.0, {"Identity (HPLC retention match)": 0.91})

    # control plan: the precondition checks, one qualitative question per check, in order
    plan = qc_test(o, CONTROL_PLAN_NAME, [{"name": c, "type": "qualitative",
                                           "ql_values": [[0, 0, {"name": "pass", "ok": True}], [0, 0, {"name": "fail", "ok": False}]]} for c in CHECKS])

    # release assay test on the "production done" trigger
    trig = o.xmlid("quality_control_mrp_oca", "qc_trigger_mrp")
    release = qc_test(o, RELEASE_TEST_NAME, [{"name": "Assay (% w/w)", "type": "quantitative", "min_value": 98.0, "max_value": 102.0}])
    if not o.search_read("qc.trigger.product_line", [["trigger", "=", trig], ["product", "=", inter["id"]], ["test", "=", release]], ["id"]):
        o.create("qc.trigger.product_line", {"trigger": trig, "product": inter["id"], "test": release, "timing": "after"})

    # fixture hygiene: no stray open order for the intermediate (the line-clear check reads them)
    for mo_open in o.search_read("mrp.production", [["product_id", "=", inter["id"]], ["state", "in", ["confirmed", "progress", "to_close"]]], ["id"]):
        o.call("mrp.production", "action_cancel", [[mo_open["id"]]])

    # history: one finished batch and its release inspection
    mo, batch_lot = done_mo(o, inter["id"], bom_id, solv["id"], good_lot, "BATCH-2026-0917", company)
    rel = first(o.search_read("qc.inspection", [["production_id", "=", mo]], ["id", "state"]))
    rel_state = rel["state"] if rel else None
    if rel and rel["state"] not in ("success", "failed"):
        _, rel_state = drive_inspection(o, rel["id"], {"Assay (% w/w)": 99.4})

    out = {"company": company, "stockLocation": stock_loc, "solventProduct": solv["id"], "intermediateProduct": inter["id"],
           "bom": bom_id, "goodLot": good_lot, "badLot": bad_lot, "incomingTest": incoming,
           "goodIncomingInspection": list(good_ins), "badIncomingInspection": list(bad_ins),
           "controlPlan": plan, "controlPlanChecks": CHECKS, "releaseTest": release,
           "historyMo": mo, "historyBatchLot": batch_lot, "historyReleaseInspection": rel["id"] if rel else None,
           "historyReleaseState": rel_state, "writes": o.writes, "reads": o.reads}
    print(json.dumps(out, indent=1))
    ok = good_ins[1] == "success" and bad_ins[1] == "failed" and rel_state == "success"
    if not ok:
        print("SEED INCOMPLETE: inspections did not reach the expected states", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
