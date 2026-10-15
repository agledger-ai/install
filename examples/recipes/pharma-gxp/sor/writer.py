#!/usr/bin/env python3
"""The system-of-record writer: creates the batch record (a manufacturing order and its
finished lot) in Odoo from exactly the payload QA approved, and returns the criteria for
calder-sor-write-receipt-v1.

    payload = build_payload(odoo, proposal)          # before the release completion: hash this
    receipt = write(odoo, payload, release_ref)      # after QA's accept verdict: sends exactly payload

`payload_hash(payload)` is what the proposer puts on the release completion and what the
receipt carries; the two must agree, and a cross-record check over the audit exports compares them.
"""
import datetime
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odoo import sha256, canon  # noqa: E402


def build_payload(o, proposal):
    prod = o.search_read("product.product", [["default_code", "=", proposal["productCode"]]], ["id"], limit=1)[0]
    model, _, bid = proposal["bomRef"].partition("/")
    return {
        "model": "mrp.production",
        "product_id": prod["id"],
        "product_qty": proposal["quantity"],
        "bom_id": int(bid),
        "lot_name": proposal["proposedLot"],
        "origin": "AGLedger release",
    }


def payload_hash(payload):
    return sha256(canon(payload))


def write(o, payload, release_ref):
    """Create the lot and the manufacturing order; returns the receipt criteria."""
    company = o.call("res.company", "search", [[]], {"limit": 1})[0]
    lot_id = o.create("stock.lot", {"name": payload["lot_name"], "product_id": payload["product_id"], "company_id": company})
    mo = o.create("mrp.production", {"product_id": payload["product_id"], "product_qty": payload["product_qty"],
                                     "bom_id": payload["bom_id"], "lot_producing_id": lot_id,
                                     "origin": "%s %s" % (payload["origin"], release_ref)})
    row = o.read("mrp.production", [mo], ["name", "write_date", "state"])[0]
    return {
        "releaseRef": release_ref,
        "sorSystem": "odoo",
        "sorModel": "mrp.production",
        "sorRecordId": str(mo),
        "sorRecordName": row["name"],
        "lotNumber": payload["lot_name"],
        "payloadHash": payload_hash(payload),
        "writeDate": str(row["write_date"]),
        "writtenAt": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    }
