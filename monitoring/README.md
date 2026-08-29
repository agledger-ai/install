# Monitoring

AGLedger exposes Prometheus-format metrics at `/metrics` on **two** processes: the API on its
service port, and the worker on its health port. They register different metrics. Federation
outbound, webhook delivery, `worker_jobs_processed`, `persist_event_unmapped` and the SIEM mapper
counters live in the worker, so an operator reading only the API's `/metrics` sees HELP/TYPE lines
with no series and concludes, reasonably and wrongly, that they are broken. Scrape both.

Metrics are unauthenticated by default. Put a reverse proxy in front if you want to gate them.

## Dashboards

Three ship, and all three auto-provision with the bundled stack:

```bash
./scripts/install.sh --with-monitoring
# Grafana: http://localhost:3003
# user admin, password generated into compose/.env as GRAFANA_ADMIN_PASSWORD
# (printed once at the end of the install)
```

| File | Answers |
|---|---|
| `compose/grafana/provisioning/dashboards/json/overview.json` | Is it up, is it fast, is it moving records, is anything saturated. **Start here.** |
| `compose/grafana/provisioning/dashboards/json/data-integrity.json` | Is the chain sound, and is federation delivering. |
| `compose/grafana/provisioning/dashboards/json/event-handlers.json` | Is anything being dropped silently. |

**Overview** covers request rate, error rate and P50/P95/P99 latency by route; records created,
completions submitted, transitions by target state, verdicts by outcome and gate duration; and the
saturation set (pool total/idle/**waiting**, pg-boss queue depth, worker job throughput, vault
anchoring and integrity checks).

**Event-handler silent drops** carries one panel per fire-and-forget path that swallows its error,
grouped by what is lost: a queued job (including one that ran and gave up after every retry), an
audit-trail entry, a federated projection, a SIEM record, or a config reload. Its top stat sums
every counter on the dashboard, which is now every drop-class counter the engine registers apart
from the ones that fail loudly somewhere else (the webhook and federation DLQs, pool and rate-limit
degradation).

Nothing here is decorative: a coverage test in the API build fails if a dashboard or alert queries a metric no process registers, and if a new drop-class counter
is added without either a panel or a written reason it does not belong on one. The class is a name
rule, `_failures_total` / `_dropped_total` / `_drops_total` / `_failed_total` / `_exhausted_total` /
`_lost_total` / `_unmapped_total`, so a counter is covered by the guard the moment it is named that
way. A counter whose name ends `_skipped_total` is deliberately outside it: a skip is a decision the
code made, carries a `reason` label, and in at least one case is documented as staying at zero
forever.

### Importing into your own Grafana

The bundled Grafana is a convenience, not a requirement.

1. Copy the JSON files above out of this repo.
2. Dashboards → New → Import → Upload JSON file.
3. Select a Prometheus data source scraping both AGLedger `/metrics` endpoints.

### Network exposure

Grafana, Prometheus, the Jaeger UI and the collector's OTLP receivers all publish on `127.0.0.1`
only, the same as the API and the database. Nothing in that stack authenticates a reader, so
reaching any of it from another host means putting it behind the reverse proxy that already
terminates TLS for the API.

## Alerting rules

`monitoring/alerts/agledger.rules.yml` ships 28 rules in five groups: silent drops, chain integrity,
partition maintenance, federation delivery, and availability/saturation.

A dashboard is the wrong delivery mechanism for the silent-drop class specifically, because that
failure is defined by nobody looking. A dropped chain append or a lost audit-trail write returns
200 to the caller, logs nothing an operator will see, and shows up only as a counter that nobody is
watching at 3am. Those rules fire at `> 0` with no `for:` delay, deliberately.

Every rule that adds several counters wraps each term as `(sum(increase(...)) or vector(0))`, and
so does the summary tile on the silent-drops dashboard. Both halves are load-bearing. Half of those
counters declare labels, and a labelled counter has no series at all until its first increment, so
`sum()` over it returns an empty vector rather than zero; adding an empty vector to anything is
empty, and the rule cannot fire. `sum()` alone fixes only the narrower case where the terms exist on
different label sets (the API and worker targets carry different `job` and `instance` values, and
PromQL arithmetic matches on the full label set). If you add a term to one of these, wrap it the
same way: the API build fails that coverage test otherwise.

Some of the rules are also unit-tested, because an alert is the one artifact whose defect is
invisible from every direction except evaluation: one that can never fire parses cleanly and loads
`health: ok`. The fixtures live in the API repo and run under `promtool test rules`. They cover eleven rules, eight of them with a negative case as well as a positive one; the
other ten are checked statically for metric names and label values, not by evaluation.

The partition rules carry the heaviest fixtures, because their failure mode is the one a
fixture is uniquely able to show: a wedged partition-management job leaves both runway gauges
frozen at their last healthy value, so the thresholds stay correctly silent on a scrape that
looks perfect. There is a fixture holding exactly that scrape flat for ten hours and asserting
that the three threshold rules do NOT fire and the two liveness rules do.

The bundled Prometheus loads them already (`rule_files` in `compose/prometheus.yml`). For your own:

```yaml
rule_files:
  - /path/to/monitoring/alerts/*.rules.yml
```

**No Alertmanager is bundled and no routing is configured.** Receivers and escalation are site
decisions, and shipping an opinion about who gets paged would be wrong. Until you add an `alerting:`
block, the rules evaluate and surface on Prometheus' own `/alerts` page. Each rule carries a
`severity` label of `critical` or `warning` as the routing hook.

## Prometheus scrape config

Minimum:

```yaml
scrape_configs:
  - job_name: agledger-api
    metrics_path: /metrics
    static_configs:
      - targets: ['agledger-api:3000']
  - job_name: agledger-worker
    metrics_path: /metrics
    static_configs:
      - targets: ['agledger-worker:3001']
```

The bundled config at `compose/prometheus.yml` is a better starting point: it discovers both
services by DNS rather than by static target, so `--scale agledger-worker=N` yields one Prometheus
target per replica instead of a single series identity that round-robins between processes and makes
counters appear to decrease.
