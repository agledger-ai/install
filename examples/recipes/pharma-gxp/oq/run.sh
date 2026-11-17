#!/usr/bin/env bash
# The scripted OQ, end to end: drive the nine cases, probe the refusals, verify every export
# offline, run the cross-record checks, and build the traceability matrix from the log.
#
#   AGLEDGER_API_URL=... AGLEDGER_API_KEY=... oq/run.sh [bundle directory, default oq-bundle]
#
# Needs: the types registered (register.sh), the system of record up (sor/setup.sh),
# Python 3.11+, and agledger-verify on PATH (or AGLEDGER_VERIFY naming the command). Run it
# against a test install: it creates agents and records, and one manufacturing order.
# Leaves in the bundle: the audit exports, case-manifest.json,
# verification-keys.json, oq.log and TRACEABILITY.md. Exit 0 iff every step passed and no
# requirement is uncovered.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-oq-bundle}"
rc=0
step(){ printf '\n===== %s =====\n' "$1"; shift; "$@" || { rc=1; echo "STEP FAILED: $*"; }; }
step "drive the cases"            python3 "$HERE/drive.py" --out "$OUT"
step "probe the refusals"         python3 "$HERE/probes.py" "$OUT"
step "verify the exports offline" python3 "$HERE/verify.py" "$OUT"
step "cross-record checks"        python3 "$HERE/crosscheck.py" "$OUT"
step "traceability matrix"        python3 "$HERE/../validation/build-matrix.py" "$OUT/oq.log" "$OUT/TRACEABILITY.md"
[ "$rc" = 0 ] && echo "OQ: PASS" || echo "OQ: FAIL"
exit $rc
