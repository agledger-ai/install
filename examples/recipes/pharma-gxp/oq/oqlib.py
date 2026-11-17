#!/usr/bin/env python3
"""What the OQ scripts share, standard library only: the AGLedger HTTP client, agent
provisioning, and the assertion log.

`Ledger.req` returns (status, body) and the caller branches on the body: a 201 completion
with `structuralValidation: INVALID` is a refusal, and a 422 carries `recoveryHint`. A 429
is retried after the wait the Server states.

Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (an admin key: the scripts provision one agent per
role with it, and the complaint-history reader searches with it).
"""
import datetime
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class Ledger:
    def __init__(self, base=None, key=None):
        base = (base or os.environ.get("AGLEDGER_API_URL") or "").rstrip("/")
        key = key or os.environ.get("AGLEDGER_API_KEY")
        if not base.startswith(("http://", "https://")) or not key:
            raise SystemExit("set AGLEDGER_API_URL (http or https) and AGLEDGER_API_KEY (an admin key)")
        self.base, self.key = base, key

    def req(self, method, path, body=None, key=None, params=None):
        url = self.base + path
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(8):
            r = urllib.request.Request(url, data, {"Authorization": "Bearer " + (key or self.key),
                                                   "Content-Type": "application/json"}, method=method)
            try:
                # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- self.base is the operator's AGLEDGER_API_URL, refused in __init__ unless its scheme is http or https
                with urllib.request.urlopen(r, timeout=60) as resp:
                    raw = resp.read()
                    return resp.status, (json.loads(raw) if raw else {})
            except urllib.error.HTTPError as e:
                raw = e.read()
                try:
                    j = json.loads(raw) if raw else {}
                except ValueError:
                    j = {"raw": raw.decode(errors="replace")}
                if e.code == 429 and attempt < 7:
                    time.sleep(float(j.get("retryAfterSeconds") or e.headers.get("retry-after") or 8))
                    continue
                return e.code, j
        return 429, {"error": "rate-limited after retries"}

    def get(self, path, key=None, params=None):
        return self.req("GET", path, key=key, params=params)

    def post(self, path, body, key=None):
        return self.req("POST", path, body, key=key)


def now(hours=0):
    return (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=hours)).isoformat().replace("+00:00", "Z")


def admitted(status, body):
    """A completion the Server took: 201 and not structurally INVALID."""
    return status == 201 and body.get("structuralValidation") != "INVALID"


def admin_org(L):
    """The org of the admin key, or exit 2: every script here needs an admin key."""
    s, me = L.get("/v1/auth/me")
    if s != 200 or me.get("role") != "admin":
        print("NOT RUN: AGLEDGER_API_KEY must be an admin key (GET /v1/auth/me answered %s, role %s)" % (s, me.get("role")))
        sys.exit(2)
    return me["orgId"]


def require_types(L, types):
    missing = [t for t in types if L.get("/v1/schemas/%s" % t)[0] != 200]
    if missing:
        print("NOT RUN: types not registered (run register.sh): %s" % ", ".join(missing))
        sys.exit(2)


def mk_agent(L, org, name):
    """One agent and one key for it. Returns {"id", "key"}."""
    s, b = L.post("/v1/admin/agents", {"orgId": org, "displayName": name})
    if s != 201:
        raise SystemExit("could not create agent %s: %s %s" % (name, s, json.dumps(b)[:300]))
    s, k = L.post("/v1/admin/api-keys", {"ownerId": b["id"], "ownerType": "agent", "role": "agent", "scopeProfile": "agent-full"})
    if s != 201:
        raise SystemExit("could not mint a key for %s: %s %s" % (name, s, json.dumps(k)[:300]))
    return {"id": b["id"], "key": k["apiKey"]}


class Claims:
    """The assertions of one script. Each is an `oqAsserts` line of validation/REQUIREMENTS.json; those that
    hold in every instance are appended to the OQ log as `<requirement id><TAB><assertion>`."""

    def __init__(self, recipe_dir):
        reqs = json.load(open(os.path.join(recipe_dir, "validation", "REQUIREMENTS.json")))["requirements"]
        self.known = {(r["id"], a) for r in reqs for a in r["oqAsserts"]}
        self.held = {}
        self.failed = 0

    @staticmethod
    def _ok(got, want):
        return got in want if isinstance(want, list) else got == want  # a list is a set of admissible values

    def claim(self, req, text, got, want, detail=""):
        assert (req, text) in self.known, "not in REQUIREMENTS.json: %s %s" % (req, text)
        ok = self._ok(got, want)
        self.held[(req, text)] = self.held.get((req, text), True) and ok
        self.failed += not ok
        print("  [%s] %s %s%s" % ("OK " if ok else "FAIL", req, text, "" if ok else " : got %s, want %s %s" % (got, want, detail)))
        return ok

    def expect(self, label, got, want):
        """A step a case depends on that is not itself an OQ assertion."""
        ok = self._ok(got, want)
        self.failed += not ok
        print("  [%s] %s%s" % ("ok " if ok else "FAIL", label, "" if ok else " : got %s, want %s" % (got, want)))
        return ok

    def append(self, log_path):
        have = set(open(log_path).read().splitlines()) if os.path.exists(log_path) else set()
        new = ["%s\t%s" % k for k, ok in sorted(self.held.items()) if ok and "%s\t%s" % k not in have]
        if new:
            with open(log_path, "a") as f:
                f.write("\n".join(new) + "\n")
        return len(new)
