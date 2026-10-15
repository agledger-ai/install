#!/usr/bin/env python3
"""The dataset readers for the complaint flow. Each reads one system, never writes, and
returns the completion evidence for calder-evidence-read-v1:

    evidence = READERS[source_system](odoo, lot_numbers, product_code, ledger=None)

What is evidence: the hash of the exact query sent, the hash of the exact bytes the system
answered, and the (model, id, write_date) stamps of every record read. The `summary` is
the reader's own words and is labelled so on the type. `mutating` is computed from the
client's write counter, not asserted.

`complaint-history` reads the ledger itself (prior calder-complaint-case-v1 records for
the product) through a callable the caller supplies; the stamps are the records' ids and
creation times, since the ledger is append-only.
"""
import datetime
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odoo import sha256, canon  # noqa: E402


def _now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def _evidence(o, source, query, result, stamps, summary):
    return {
        "sourceSystem": source,
        "query": query[:2000],
        "queryHash": sha256(query),
        "resultHash": sha256(canon(result)),
        "recordCount": len(stamps),
        "sourceRecords": stamps,
        "readAt": _now(),
        "mutating": o.writes > 0,
        "summary": summary[:1000],
    }


def read_mes(o, lots, product_code, ledger=None):
    """Manufacturing orders that produced the named lots, with the component lots consumed."""
    writes0 = o.writes
    lot_rows = o.search_read("stock.lot", [["name", "in", lots]], ["id", "name", "product_id"])
    mos = o.search_read("mrp.production", [["lot_producing_id", "in", [r["id"] for r in lot_rows]]],
                        ["id", "name", "state", "product_id", "qty_produced", "lot_producing_id", "move_raw_ids", "date_finished"])
    raw_ids = [i for m in mos for i in m["move_raw_ids"]]
    raw = o.read("stock.move", raw_ids, ["id", "product_id", "quantity", "move_line_ids"]) if raw_ids else []
    ml_ids = [i for r in raw for i in r["move_line_ids"]]
    mls = o.read("stock.move.line", ml_ids, ["id", "lot_id", "quantity"]) if ml_ids else []
    query = canon({"stock.lot": [["name", "in", lots]], "mrp.production": "lot_producing_id in lots", "stock.move": "move_raw_ids", "stock.move.line": "move_line_ids"}).decode()
    result = {"lots": lot_rows, "orders": mos, "rawMoves": raw, "rawLines": mls}
    stamps = o.stamps("stock.lot", [r["id"] for r in lot_rows]) + o.stamps("mrp.production", [m["id"] for m in mos]) \
        + o.stamps("stock.move", raw_ids) + o.stamps("stock.move.line", ml_ids)
    consumed = sorted({ml["lot_id"][1] for ml in mls if ml["lot_id"]})
    summary = "%d order(s) produced %s; component lots consumed: %s; states: %s" % (
        len(mos), ",".join(lots), ",".join(consumed) or "none", ",".join(m["state"] for m in mos))
    assert o.writes == writes0
    return _evidence(o, "mes", query, result, stamps, summary)


def read_lims(o, lots, product_code, ledger=None):
    """Inspections on the named lots, on the orders that produced them, and on the component lots consumed."""
    lot_rows = o.search_read("stock.lot", [["name", "in", lots]], ["id", "name"])
    lot_ids = [r["id"] for r in lot_rows]
    mos = o.search_read("mrp.production", [["lot_producing_id", "in", lot_ids]], ["id", "move_raw_ids"])
    raw_ids = [i for m in mos for i in m["move_raw_ids"]]
    mls = o.search_read("stock.move.line", [["move_id", "in", raw_ids]], ["lot_id"]) if raw_ids else []
    comp_lot_ids = sorted({ml["lot_id"][0] for ml in mls if ml["lot_id"]})
    domain = ["|", "|", ["production_id", "in", [m["id"] for m in mos]],
              ["object_id", "in", ["stock.lot,%d" % i for i in lot_ids + comp_lot_ids]],
              ["lot_id", "in", lot_ids + comp_lot_ids]]
    ins = o.search_read("qc.inspection", domain, ["id", "name", "state", "success", "object_id", "production_id", "test", "inspection_lines"])
    line_ids = [i for r in ins for i in r["inspection_lines"]]
    lines = o.read("qc.inspection.line", line_ids, ["id", "name", "quantitative_value", "min_value", "max_value", "success"]) if line_ids else []
    query = canon({"qc.inspection": domain, "qc.inspection.line": "inspection_lines"}).decode()
    result = {"inspections": ins, "lines": lines}
    stamps = o.stamps("qc.inspection", [r["id"] for r in ins]) + o.stamps("qc.inspection.line", line_ids)
    summary = "%d inspection(s): %s" % (len(ins), "; ".join("%s %s" % (r["name"], r["state"]) for r in ins) or "none")
    return _evidence(o, "lims", query, result, stamps, summary)


def read_distribution(o, lots, product_code, ledger=None):
    """Outbound movements of the named lots (deliveries), from the stock move lines."""
    lot_rows = o.search_read("stock.lot", [["name", "in", lots]], ["id"])
    domain = [["lot_id", "in", [r["id"] for r in lot_rows]], ["location_dest_id.usage", "in", ["customer", "transit"]], ["state", "=", "done"]]
    mls = o.search_read("stock.move.line", domain, ["id", "lot_id", "quantity", "location_dest_id", "date", "reference"])
    query = canon({"stock.move.line": domain}).decode()
    stamps = o.stamps("stock.move.line", [r["id"] for r in mls])
    shipped = sum(r["quantity"] for r in mls)
    summary = "%d outbound line(s), %.1f units shipped to customers or transit" % (len(mls), shipped)
    return _evidence(o, "distribution", query, {"lines": mls}, stamps, summary)


def read_complaint_history(o, lots, product_code, ledger=None):
    """Prior complaint cases for the product on the ledger. `ledger(product_code)` returns
    [{"id": ..., "createdAt": ..., "status": ...}] from GET /v1/records/search?type=...&criteria[productCode]=."""
    rows = ledger(product_code) if ledger else []
    query = "GET /v1/records/search?type=calder-complaint-case-v1&criteria[productCode]=%s" % product_code
    stamps = [{"model": "agledger.record", "id": r["id"], "writeDate": r["createdAt"]} for r in rows]
    summary = "%d prior complaint case(s) for %s on the ledger" % (len(rows), product_code)
    return _evidence(o, "complaint-history", query, {"records": rows}, stamps, summary)


READERS = {
    "mes": read_mes,
    "lims": read_lims,
    "distribution": read_distribution,
    "complaint-history": read_complaint_history,
}
