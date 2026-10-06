#!/usr/bin/env python3
"""
Fleet drift triage: the deterministic half of an ops loop over GET /v1/agents/drift.

One tick does four things and nothing else:

  1. Pages the whole fleet series (GET /v1/agents/drift?window=W, cursor-paged).
  2. Selects the agents whose numbers moved between the baseline window and the
     current window, in either direction. The endpoint carries no score, no
     threshold and no filter, so selection is this script's rule, stated below.
  3. For each selected agent, pulls the per-type breakdown
     (GET /v1/agents/{id}/drift) and the current-window record feed
     (GET /v1/agents/{id}/history?from=&to=), so whoever decides has the
     records behind the counts, not just the counts.
  4. Writes one JSON dossier per tick and prints a short text summary.

What it does NOT do: judge. A change is a change; whether it is good is for the
principal watching the agent (the OPS-AGENT.md brief covers that half).

Selection rule (the two operator choices are flags, defaults shown):
  - any count field differing between the windows selects the agent
    (records, completions, verdicts, accepted, rejected, overturned);
  - an acceptance rate that differs selects the agent (0.8 -> 1.0 counts, so
    does 0.8 -> 0.6). The engine's own `change.acceptanceRate` is null when
    either window has no verdict, so the comparison is made on the two window
    values, not on `change`;
  - median completion time selects only when it moved by more than
    --median-ratio (default 2.0x), because a millisecond median moves on every
    tick for any agent that completed anything;
  - an agent idle in both windows is never selected; one active in exactly
    one window is selected as `new` or `quiet`.

Env: AGLEDGER_API_URL, AGLEDGER_API_KEY (an admin key in the org; needs drift:read,
which admin-standard and admin-observer both carry).
"""
import argparse, json, os, sys, time, urllib.error, urllib.parse, urllib.request

COUNTS = ('records', 'completions', 'verdicts', 'accepted', 'rejected', 'overturned')


def api_base(raw):
    """Refuse anything but http/https. urllib would happily open file:// or
    ftp://, and this script gets copied into places where the base URL is not
    always as trusted as an operator's own shell."""
    u = urllib.parse.urlparse(raw)
    if u.scheme not in ('http', 'https'):
        sys.exit(f"AGLEDGER_API_URL must be http or https, got {u.scheme or 'no'} scheme: {raw}")
    if not u.netloc:
        sys.exit(f'AGLEDGER_API_URL has no host: {raw}')
    return raw.rstrip('/')


def api(base, key, path, params=None):
    q = {k: v for k, v in (params or {}).items() if v is not None}
    url = base.rstrip('/') + path + (('?' + urllib.parse.urlencode(q)) if q else '')
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {key}', 'Accept': 'application/json'})
    try:
        # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- scheme is pinned to http/https by api_base() in main()
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b'{}'), {k.lower(): v for k, v in r.headers.items()}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            body = json.loads(raw)
        except Exception:
            body = {'raw': raw.decode('utf-8', 'replace')}
        return e.code, body, {k.lower(): v for k, v in e.headers.items()}


def page_all(base, key, path, params, limit, max_pages=None):
    """Walk a cursor-paged list to the end. Returns (rows, last_body, calls, waited_s)."""
    rows, cursor, calls, waited = [], None, 0, 0
    while True:
        st, body, h = api(base, key, path, {**params, 'limit': limit, 'cursor': cursor})
        calls += 1
        if st == 429:
            ra = int(h.get('retry-after') or 1)
            time.sleep(ra); waited += ra
            continue
        if st != 200:
            sys.exit(f'{path}: HTTP {st} {json.dumps(body)[:500]}')
        rows.extend(body.get('data') or [])
        cursor = body.get('nextCursor')
        if not body.get('hasMore') or not cursor or (max_pages and calls >= max_pages):
            return rows, body, calls, waited


def active(w):
    return any((w.get(k) or 0) for k in COUNTS)


def classify(row, median_ratio):
    c, b = row['current'], row['baseline']
    if not active(c) and not active(b):
        return None
    if active(c) and not active(b):
        cls = 'new'
    elif active(b) and not active(c):
        cls = 'quiet'
    else:
        cls = 'shifted'
    moved = [k for k in COUNTS if (c.get(k) or 0) != (b.get(k) or 0)]
    rate = None
    if c.get('acceptanceRate') != b.get('acceptanceRate'):
        rate = [b.get('acceptanceRate'), c.get('acceptanceRate')]
    med = None
    cm, bm = c.get('medianCompletionMs'), b.get('medianCompletionMs')
    if cm is not None and bm is not None and bm > 0 and cm > 0:
        r = cm / bm
        if r >= median_ratio or r <= 1 / median_ratio:
            med = [bm, cm]
    if cls == 'shifted' and not moved and rate is None and med is None:
        return None
    return {'class': cls, 'movedCounts': moved, 'acceptanceRate': rate, 'medianCompletionMs': med}


def summarize_history(rows):
    by = {'type': {}, 'status': {}, 'role': {}, 'outcome': {}}
    for r in rows:
        for k in by:
            v = r.get(k) if r.get(k) is not None else 'none'
            by[k][v] = by[k].get(v, 0) + 1
    return by


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--window', type=int, default=7, help='window length in days (engine: 1..365)')
    ap.add_argument('--page-size', type=int, default=100, help='fleet page size (engine max 100)')
    ap.add_argument('--median-ratio', type=float, default=2.0, help='median completion time must move by this factor to count')
    ap.add_argument('--history-limit', type=int, default=200, help='max current-window history rows pulled per mover')
    ap.add_argument('--json', default=None, help='write the tick dossier here (default: stdout summary only)')
    ap.add_argument('--quiet', action='store_true', help='no text summary')
    a = ap.parse_args()

    base = api_base(os.environ.get('AGLEDGER_API_URL') or sys.exit('AGLEDGER_API_URL not set'))
    key = os.environ.get('AGLEDGER_API_KEY') or sys.exit('AGLEDGER_API_KEY not set')

    t0 = time.time()
    fleet, last, calls, waited = page_all(base, key, '/v1/agents/drift', {'window': a.window}, a.page_size)
    window = last.get('window') or {}
    total = last.get('total')

    movers = []
    for row in fleet:
        sel = classify(row, a.median_ratio)
        if not sel:
            continue
        aid = row['agentId']
        st, detail, _ = api(base, key, f'/v1/agents/{aid}/drift', {'window': a.window})
        by_type = detail.get('byType') if st == 200 else {'error': st, 'body': detail}
        hist, _, hcalls, hw = page_all(base, key, f'/v1/agents/{aid}/history',
                                       {'from': window.get('currentFrom'), 'to': window.get('currentTo')},
                                       min(a.history_limit, 100), max_pages=max(1, a.history_limit // 100))
        calls += 1 + hcalls; waited += hw
        movers.append({
            'agentId': aid, 'displayName': row.get('displayName'), **sel,
            'current': row['current'], 'baseline': row['baseline'], 'change': row.get('change'),
            'byType': by_type,
            'historyCurrentWindow': {'rows': len(hist), 'truncated': len(hist) >= a.history_limit,
                                     'summary': summarize_history(hist), 'sample': hist[:10]},
        })

    tick = {
        'tickAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'window': window,
        'fleet': {'total': total, 'seriesReturned': len(fleet),
                  'idleBothWindows': sum(1 for r in fleet if not active(r['current']) and not active(r['baseline']))},
        'rule': {'countChange': 'any', 'acceptanceRate': 'any change', 'medianRatio': a.median_ratio},
        'calls': calls, 'rateLimitWaitSeconds': waited, 'elapsedSeconds': round(time.time() - t0, 2),
        'movers': movers,
    }
    if a.json:
        os.makedirs(os.path.dirname(os.path.abspath(a.json)), exist_ok=True)
        with open(a.json, 'w') as f:
            json.dump(tick, f, indent=2)
    if not a.quiet:
        print(f"drift tick {tick['tickAt']}  window={window.get('days')}d  fleet={total}  series={len(fleet)}  "
              f"idle-both={tick['fleet']['idleBothWindows']}  movers={len(movers)}  calls={calls}  "
              f"waited={waited}s  {tick['elapsedSeconds']}s")
        for m in movers:
            bits = []
            if m['movedCounts']:
                bits.append('counts ' + ','.join(f"{k} {m['baseline'].get(k, 0)}->{m['current'].get(k, 0)}" for k in m['movedCounts']))
            if m['acceptanceRate']:
                bits.append(f"acceptanceRate {m['acceptanceRate'][0]}->{m['acceptanceRate'][1]}")
            if m['medianCompletionMs']:
                bits.append(f"medianCompletionMs {m['medianCompletionMs'][0]}->{m['medianCompletionMs'][1]}")
            types = [t.get('type') for t in (m['byType'] or [])] if isinstance(m['byType'], list) else ['?']
            print(f"  {m['class']:8s} {m['agentId']}  {m.get('displayName') or ''}")
            print(f"           {'; '.join(bits)}")
            print(f"           types {types}  history rows in window {m['historyCurrentWindow']['rows']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
