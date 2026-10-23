#!/usr/bin/env python3
"""Minimal Odoo JSON-RPC client, standard library only.

Every call this recipe makes to the system of record goes through `Odoo.call`, which
records whether the method is a read or a write (`reads` / `writes` counters) and keeps
the exact request and response bytes of the last call, so an automation can hash what
it sent and what the system answered. The readers in the complaint flow assert
`writes == 0` before they sign their evidence; that is where `mutating: false` comes from.

Env: ODOO_URL (default http://127.0.0.1:18069), ODOO_DB (gxp), ODOO_LOGIN (admin),
ODOO_PASSWORD (gxp-admin).
"""
import hashlib
import json
import os
import urllib.request

READ_METHODS = {"search", "search_read", "read", "search_count", "fields_get", "name_get",
                "check_object_reference", "read_group"}


def sha256(data):
    if isinstance(data, str):
        data = data.encode()
    return "sha256:" + hashlib.sha256(data).hexdigest()


def canon(obj):
    """Canonical JSON bytes (sorted keys, no whitespace) for hashing."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode()


class Odoo:
    def __init__(self, url=None, db=None, login=None, password=None):
        base = (url or os.environ.get("ODOO_URL", "http://127.0.0.1:18069")).rstrip("/")
        if not base.startswith(("http://", "https://")):
            raise ValueError("ODOO_URL must be an http or https URL, got %r" % base)
        self.url = base + "/jsonrpc"
        self.db = db or os.environ.get("ODOO_DB", "gxp")
        self.login = login or os.environ.get("ODOO_LOGIN", "admin")
        self.password = password or os.environ.get("ODOO_PASSWORD", "gxp-admin")
        self._id = 0
        self.reads = 0
        self.writes = 0
        self.last_request = b""
        self.last_response = b""
        self.uid = self._rpc("common", "authenticate", self.db, self.login, self.password, {})
        if not self.uid:
            raise RuntimeError("odoo authentication failed")

    def _rpc(self, service, method, *args):
        self._id += 1
        body = canon({"jsonrpc": "2.0", "method": "call", "id": self._id,
                      "params": {"service": service, "method": method, "args": list(args)}})
        req = urllib.request.Request(self.url, body, {"Content-Type": "application/json"})
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- self.url is the operator's ODOO_URL, refused in __init__ unless its scheme is http or https
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
        self.last_request, self.last_response = body, raw
        out = json.loads(raw)
        if "error" in out:
            e = out["error"]
            raise RuntimeError("odoo rpc error: %s: %s" % (e.get("message"), (e.get("data") or {}).get("message")))
        return out.get("result")

    def call(self, model, method, args=None, kw=None):
        if method in READ_METHODS:
            self.reads += 1
        else:
            self.writes += 1
        return self._rpc("object", "execute_kw", self.db, self.uid, self.password, model, method, args or [], kw or {})

    # convenience
    def search_read(self, model, domain, fields, limit=None, order=None):
        kw = {"fields": list(fields)}
        if limit:
            kw["limit"] = limit
        if order:
            kw["order"] = order
        return self.call(model, "search_read", [domain], kw)

    def read(self, model, ids, fields):
        return self.call(model, "read", [list(ids), list(fields)])

    def create(self, model, vals, ctx=None):
        return self.call(model, "create", [vals], {"context": ctx or {}})

    def write(self, model, ids, vals):
        return self.call(model, "write", [list(ids), vals])

    def xmlid(self, module, name):
        return self.call("ir.model.data", "check_object_reference", [module, name])[1]

    def stamps(self, model, ids):
        """(model, id, write_date) tuples: the source's own last-write stamps."""
        if not ids:
            return []
        rows = self.read(model, ids, ["write_date"])
        return [{"model": model, "id": str(r["id"]), "writeDate": str(r["write_date"])} for r in rows]


def stamp_digest(stamps):
    """Order-independent digest over (model, id, writeDate) tuples."""
    key = sorted((s["model"], s["id"], s["writeDate"]) for s in stamps)
    return sha256(canon(key))
