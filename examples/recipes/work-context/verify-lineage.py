#!/usr/bin/env python3
"""
Lineage-coherence checker for the Agent Work Context recipe.

The server notarizes checkpoints; it does NOT judge their lineage claims
(notarize-only by design). supersedesRecordId is signed content, so all of the
following land as 201s and verify clean offline: two checkpoints superseding
the same head (a fork, e.g. two occupants resuming concurrently), a
supersedesRecordId naming a nonexistent record, one naming a checkpoint under
a DIFFERENT root, and a second `initial` under one root. This tool is the
client-side check the recipe's schema guards cannot provide.

Usage:  verify-lineage.py <rootRecordId>
  Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (seat key; read access to the tree).

Fetches every work-context-v1 child of the root (cursor pagination) and checks:
  1. exactly one `initial` checkpoint;
  2. every non-initial supersedesRecordId resolves to a sibling under THIS
     root (catches dangling and cross-root pointers);
  3. no record is superseded by more than one checkpoint (catches forks);
  4. the supersedes chain from the initial is a single path covering every
     checkpoint, and its terminus is the record nothing supersedes;
  5. the terminus agrees with the head query's newest-first answer (data[0]);
  6. a `final` checkpoint, if present, is the terminus.

Exit 0 iff all checks pass. A fork is not tamper: every branch is genuinely
signed. It is two occupants that raced; the fix is a new checkpoint that
supersedes the branch you are keeping (record the merge, don't rewrite).
"""
import json, os, sys, urllib.parse, urllib.request

TYPE = "work-context-v1"


def fetch_children(api, key, root):
    out, cursor = [], None
    while True:
        q = {"parentRecordId": root, "type": TYPE, "limit": "50"}
        if cursor:
            q["cursor"] = cursor
        req = urllib.request.Request(
            f"{api}/v1/records/search?{urllib.parse.urlencode(q)}",
            headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req) as r:
            body = json.load(r)
        out.extend(body["data"])
        if not body.get("hasMore"):
            return out
        cursor = body["nextCursor"]


def main():
    api, key = os.environ["AGLEDGER_API_URL"], os.environ["AGLEDGER_API_KEY"]
    root = sys.argv[1]
    rows = fetch_children(api, key, root)
    if not rows:
        print(f"no {TYPE} children under root {root}")
        return 1
    by_id = {r["id"]: r for r in rows}
    newest = rows[0]["id"]  # search returns newest first (by server createdAt)
    fail = 0

    def check(ok, label, detail=""):
        nonlocal fail
        print(f"[{'OK ' if ok else 'BAD'}] {label}" + (f": {detail}" if detail else ""))
        if not ok:
            fail = 1

    initials = [r["id"] for r in rows
                if r["criteria"].get("checkpointReason") == "initial"]
    check(len(initials) == 1, "exactly one initial checkpoint",
          f"found {len(initials)}: {initials}" if len(initials) != 1 else initials[0])

    sup = {r["id"]: r["criteria"].get("supersedesRecordId")
           for r in rows if r["criteria"].get("checkpointReason") != "initial"}
    dangling = {i: s for i, s in sup.items() if s not in by_id}
    check(not dangling, "every supersedesRecordId resolves under this root",
          "; ".join(f"{i} -> {s} (not a {TYPE} child of this root)"
                    for i, s in dangling.items()))

    targets = {}
    for i, s in sup.items():
        targets.setdefault(s, []).append(i)
    forks = {s: ids for s, ids in targets.items() if len(ids) > 1 and s in by_id}
    check(not forks, "no record superseded twice (fork)",
          "; ".join(f"{s} superseded by BOTH {ids}" for s, ids in forks.items()))

    terminals = [i for i in by_id if i not in targets]
    if len(initials) == 1 and not dangling and not forks:
        chain, cur = [], initials[0]
        while cur:
            chain.append(cur)
            nxt = targets.get(cur, [])
            cur = nxt[0] if nxt else None
        check(len(chain) == len(rows), "single chain covers every checkpoint",
              f"chain {len(chain)} of {len(rows)}")
        check(terminals == [chain[-1]], "terminus is the un-superseded record")
        terminus = chain[-1]
    else:
        check(False, "single chain covers every checkpoint",
              f"skipped; terminals: {terminals}")
        terminus = None

    if terminus:
        check(terminus == newest, "lineage terminus == head query data[0]",
              f"terminus {terminus} vs newest {newest}")
        finals = [r["id"] for r in rows
                  if r["criteria"].get("checkpointReason") == "final"]
        check(all(f == terminus for f in finals),
              "any final checkpoint is the terminus",
              f"finals {finals}, terminus {terminus}" if finals else "no final yet")

    print(f"\nLINEAGE {'COHERENT' if not fail else 'INCOHERENT'} "
          f"({len(rows)} checkpoints under {root})")
    return fail


if __name__ == "__main__":
    sys.exit(main())
