#!/usr/bin/env python3
"""The system-of-record writer: creates the batch record (a manufacturing order and its
finished lot) in Odoo from exactly the payload QA approved, and returns the criteria for
calder-sor-write-receipt-v1.

    payload = build_payload(odoo, proposal)              # before the release completion: hash this
    receipt = write(odoo, payload, release_ref, ledger)  # after QA's accept verdict: sends exactly payload

`payload_hash(payload)` is what the proposer puts on the release completion and what the
receipt carries; the two must agree, and a cross-record check over the audit exports compares them.

`write` does not take the caller's word that QA approved. It re-reads the release from the
ledger first (`authorize`) and raises `Refused`, having written nothing, unless the release
reads FULFILLED on an accept verdict, its completion binds this payload's hash, the check
that completion names is a FULFILLED child of the release performed by the checker the
release names, and that check is no older than the release's maxCheckAgeMinutes.

`ledger` is a callable you supply: `ledger(path)` issues GET `path` against your AGLedger
Server and returns `(status, body)`. An agent key reads only the records it is a party to,
and the writer is a party to none of these, so give it a read-only key (an admin key minted
with scopeProfile `admin-observer`: it reads records and completions and can sign nothing).
"""
import datetime
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from odoo import sha256, canon  # noqa: E402

RELEASE_T, CHECK_T = "calder-batch-record-release-v1", "calder-precondition-check-v1"


class Refused(Exception):
    """The release, as the ledger reads it now, does not authorize this write."""


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


def _when(stamp):
    return datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def authorize(ledger, payload, release_ref, at=None):
    """Re-read the release and its check from the ledger. Returns the check's age in minutes, or raises Refused."""
    def get(path):
        status, body = ledger(path)
        if status != 200:
            raise Refused("GET %s answered %s" % (path, status))
        return body

    def own_completions(record_id):
        """What the performer submitted and the Server took, oldest first (not a rollup the engine synthesized)."""
        rows = get("/v1/records/%s/completions" % record_id).get("data", [])
        return sorted((c for c in rows if not c.get("rollupSynthesized") and c.get("structuralValidation") != "INVALID"), key=lambda c: c["createdAt"])

    rel = get("/v1/records/%s" % release_ref)
    if (rel.get("type"), rel.get("status"), rel.get("verdict")) != (RELEASE_T, "FULFILLED", "accept"):
        raise Refused("release %s reads %s %s (verdict %s), not a FULFILLED release on an accept verdict" % (release_ref, rel.get("type"), rel.get("status"), rel.get("verdict")))
    done = own_completions(release_ref)
    approved = done[-1]["evidence"] if done else {}
    if approved.get("payloadHash") != payload_hash(payload):
        raise Refused("the approved completion binds %s, this payload hashes to %s" % (approved.get("payloadHash"), payload_hash(payload)))
    check = get("/v1/records/%s" % approved.get("checkRef"))
    crit = rel.get("criteria", {})
    if (check.get("type"), check.get("parentRecordId"), check.get("status")) != (CHECK_T, release_ref, "FULFILLED"):
        raise Refused("checkRef %s is not a FULFILLED precondition check under this release" % approved.get("checkRef"))
    if check.get("performerAgentId") != crit.get("checkerAgentId"):
        raise Refused("the check was performed by %s, the release names %s" % (check.get("performerAgentId"), crit.get("checkerAgentId")))
    checked = own_completions(check["id"])
    limit = crit.get("maxCheckAgeMinutes")
    if not checked or not isinstance(limit, int):
        raise Refused("the check has no completion, or the release carries no maxCheckAgeMinutes")
    age = ((at or datetime.datetime.now(datetime.timezone.utc)) - _when(checked[-1]["createdAt"])).total_seconds() / 60
    if age > limit:
        raise Refused("the check is %.1f minutes old, the release allows %d" % (age, limit))
    return age


def write(o, payload, release_ref, ledger):
    """Create the lot and the manufacturing order, if the ledger authorizes it; returns the receipt criteria."""
    authorize(ledger, payload, release_ref)
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
