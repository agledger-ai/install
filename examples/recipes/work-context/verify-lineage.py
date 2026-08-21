#!/usr/bin/env python3
"""
Lineage-coherence checker for the Agent Work Context recipe.

The server notarizes checkpoints; it does NOT judge their lineage claims
(notarize-only by design). supersedesRecordId is a first-class signed record
field, so the engine does resolve the target and refuses a create naming a
record that does not exist in your org. What it deliberately does not judge is
whether the lineage makes sense for THIS recipe, so all of the following land
as 201s and verify clean offline: two checkpoints superseding the same head (a
fork, e.g. two sessions resuming concurrently), one naming a checkpoint under a
DIFFERENT root, a checkpoint that supersedes nothing when it should have, and a
second `initial` under one root. This tool is the client-side check.

Note the one-call version of check 2 that the server now answers directly:
`GET /v1/records/search?parentRecordId=<root>&type=work-context-v1&superseded=false`
returns the live head, and returns more than one row exactly when the tree has
forked. This script stays useful because it walks the whole chain and reports
WHERE the break is, which a head query cannot.

Usage:  verify-lineage.py <rootRecordId>
  Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (agent key; read access to the tree).

Fetches every work-context-v1 child of the root (cursor pagination) and checks:
  1. exactly one `initial` checkpoint;
  2. the initial checkpoint supersedes nothing (it is the first under this
     root, so there is nothing under it to replace);
  3. every non-initial checkpoint supersedes something;
  4. every supersedesRecordId, on any checkpoint, resolves to a sibling under
     THIS root (catches cross-root pointers);
  5. no record is superseded by more than one checkpoint (catches forks);
  6. the supersedes chain from the initial is a single path covering every
     checkpoint, and its terminus is the record nothing supersedes;
  7. the terminus agrees with the head query's newest-first answer (data[0]);
  8. a `final` checkpoint, if present, is the terminus.

Checks 2 and 4 read every checkpoint, `initial` included. Leaving `initial` out
of the supersession map hides the cross-root supersession in the shape it most
often arrives in: a session opening work on a new root, carrying over a head id
it read from a different one. That checkpoint is `initial` by convention, so it
would be in none of the checks, and BOTH roots would report coherent while the
victim root's head query returned nothing.

Exit 0 iff all checks pass. A fork is not tamper: every branch is genuinely
signed. It is two sessions that raced; the fix is a new checkpoint that
supersedes the branch you are keeping (record the merge, don't rewrite).
"""
import json, os, sys, urllib.parse, urllib.request

TYPE = "work-context-v1"


def api_base(raw):
    """Refuse anything but http/https. urllib would happily open file:// or
    ftp://, and this script gets copied into places where the base URL is not
    always as trusted as an operator's own shell."""
    u = urllib.parse.urlparse(raw)
    if u.scheme not in ("http", "https"):
        sys.exit(f"AGLEDGER_API_URL must be http or https, got {u.scheme or 'no'} scheme: {raw}")
    if not u.netloc:
        sys.exit(f"AGLEDGER_API_URL has no host: {raw}")
    return raw.rstrip("/")


def fetch_children(api, key, root):
    out, cursor = [], None
    while True:
        q = {"parentRecordId": root, "type": TYPE, "limit": "50"}
        if cursor:
            q["cursor"] = cursor
        req = urllib.request.Request(
            f"{api}/v1/records/search?{urllib.parse.urlencode(q)}",
            headers={"Authorization": f"Bearer {key}"})
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- scheme is pinned to http/https by api_base() above
        with urllib.request.urlopen(req) as r:
            body = json.load(r)
        out.extend(body["data"])
        if not body.get("hasMore"):
            return out
        cursor = body["nextCursor"]


def main():
    api, key = api_base(os.environ["AGLEDGER_API_URL"]), os.environ["AGLEDGER_API_KEY"]
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

    # First-class record field, not criteria: the engine validated that it
    # resolves to a record in this org, so a non-None value here can only be
    # wrong by pointing outside this root, never by dangling.
    #
    # Every checkpoint is in this map, `initial` included. An initial that
    # supersedes something is a fault in its own right (see below), and it is
    # also the shape a cross-root supersession usually arrives in, so leaving
    # initials out took them out of the off-root and fork checks too.
    sup = {r["id"]: r.get("supersedesRecordId") for r in rows}

    # An initial checkpoint is the first under its root, so there is nothing
    # under that root for it to replace. A value here is therefore always one
    # of two mistakes: a head id carried over from a DIFFERENT root (the
    # off-root check below names the target), or a checkpoint that is not
    # really the initial one.
    initial_supersedes = {i: sup[i] for i in initials if sup.get(i) is not None}
    check(not initial_supersedes, "the initial checkpoint supersedes nothing",
          "; ".join(f"{i} -> {s} (an initial checkpoint has nothing under this "
                    f"root to replace; if {s} is under another root, that root's "
                    f"head query now returns nothing)"
                    for i, s in initial_supersedes.items()))

    # Two distinct faults, reported separately because the fixes differ. Missing:
    # the checkpoint superseded nothing, so the old head is still live and the
    # tree now reads as forked. Off-root: it superseded a real record belonging
    # to some other piece of work.
    missing = [i for i, s in sup.items()
               if s is None and by_id[i]["criteria"].get("checkpointReason") != "initial"]
    check(not missing, "every non-initial checkpoint supersedes something",
          "; ".join(f"{i} (old head stays current, so this reads as a fork)"
                    for i in missing))

    off_root = {i: s for i, s in sup.items() if s is not None and s not in by_id}
    check(not off_root, "every supersedesRecordId resolves under this root",
          "; ".join(f"{i} -> {s} (not a {TYPE} child of this root)"
                    for i, s in off_root.items()))
    dangling = {**{i: None for i in missing}, **off_root, **initial_supersedes}

    targets = {}
    for i, s in sup.items():
        targets.setdefault(s, []).append(i)
    forks = {s: ids for s, ids in targets.items() if len(ids) > 1 and s in by_id}
    check(not forks, "no record superseded twice (fork)",
          "; ".join(f"{s} superseded by BOTH {ids}" for s, ids in forks.items()))

    terminals = [i for i in by_id if i not in targets]
    if len(initials) == 1 and not dangling and not forks:
        chain, cur = [], initials[0]
        # Bounded by the row count: a cycle (A supersedes B, B supersedes A)
        # is reachable from the initial once initials carry pointers, and an
        # unbounded walk would hang here rather than report it.
        while cur and len(chain) <= len(rows):
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
