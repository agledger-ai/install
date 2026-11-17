#!/usr/bin/env python3
"""Verify every audit export in the bundle offline with the published verifier, against the
keys saved from GET /v1/verification-keys, and confirm it reports an altered export.

The verifier is `agledger-verify` (the `@agledger/verify` package, 2.1.0 or later). Name
another command in AGLEDGER_VERIFY, with any arguments it should always get: to pin the
vault key digest the installer printed, for example,

    AGLEDGER_VERIFY='agledger-verify --trust-anchor sha256:<hex>' python3 oq/verify.py

Keys embedded in an export are refused (--require-supplied-keys): only verification-keys.json
counts. The negative control copies one export, changes one character of the first entry's
signed envelope, and must be reported invalid.

    python3 oq/verify.py [bundle directory, default oq-bundle]

Assertions that hold are appended to `oq.log` in the bundle. Exit 0 iff every export
verifies and the altered one does not, 2 when the verifier or the bundle is missing.
"""
import glob
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from oqlib import Claims  # noqa: E402

OUT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else "oq-bundle")
CMD = shlex.split(os.environ.get("AGLEDGER_VERIFY", "agledger-verify"))
KEYS = os.path.join(OUT, "verification-keys.json")
EXPORTS = sorted(glob.glob(os.path.join(OUT, "*.audit-export.json")))
if not EXPORTS or not os.path.exists(KEYS):
    print("NOT RUN: no audit exports or no verification-keys.json in %s (run oq/drive.py)" % OUT)
    sys.exit(2)
if not shutil.which(CMD[0]):
    print("NOT RUN: %s is not on PATH. Install @agledger/verify, or set AGLEDGER_VERIFY to the command." % CMD[0])
    sys.exit(2)


def verify(path):
    """(valid, detail) from the verifier's JSON report. Anything but a report that says valid is not valid."""
    p = subprocess.run(CMD + [path, "--report-format", "json", "--keys", KEYS, "--require-supplied-keys"], capture_output=True, text=True)
    try:
        rep = json.loads(p.stdout)
    except ValueError:
        return False, "exit %s, no JSON report: %s" % (p.returncode, (p.stdout + p.stderr).strip()[-200:])
    ok = rep.get("valid") is True and p.returncode == 0 and rep.get("verifiedEntries") == rep.get("totalEntries")
    return ok, "exit %s verdict %s, %s of %s entries" % (p.returncode, rep.get("verdict"), rep.get("verifiedEntries"), rep.get("totalEntries"))


C = Claims(os.path.dirname(HERE))
bad = []
for f in EXPORTS:
    ok, detail = verify(f)
    if not ok:
        bad.append("%s: %s" % (os.path.basename(f), detail))
        print("    %s: %s" % (os.path.basename(f), detail))
C.claim("GXP-18", "every record's audit export verifies against the Server's verification keys", (len(EXPORTS) > 0, bad), (True, []))

with tempfile.TemporaryDirectory() as tmp:
    d = json.load(open(EXPORTS[0]))
    env = d["entries"][0]["integrity"]["coseSign1"]
    d["entries"][0]["integrity"]["coseSign1"] = env[:20] + ("B" if env[20] != "B" else "C") + env[21:]
    altered = os.path.join(tmp, os.path.basename(EXPORTS[0]))
    json.dump(d, open(altered, "w"))
    ok, detail = verify(altered)
C.claim("GXP-18", "an export with one altered byte is reported as invalid", ok, False, "(%s)" % detail)

added = C.append(os.path.join(OUT, "oq.log"))
print("\nverify: %s (%d export(s); %d assertion(s) added to %s)" % ("PASS" if C.failed == 0 else "FAIL", len(EXPORTS), added, os.path.join(OUT, "oq.log")))
sys.exit(0 if C.failed == 0 else 1)
