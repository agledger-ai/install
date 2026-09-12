# Monitoring

AGLedger exposes Prometheus-format metrics at `/metrics` on **two** processes: the API on its
service port, and the worker on its health port. They register different metrics. Federation
outbound, webhook delivery, `worker_jobs_processed`, `persist_event_unmapped` and the SIEM mapper
counters live in the worker, so an operator reading only the API's `/metrics` sees HELP/TYPE lines
with no series and concludes, reasonably and wrongly, that they are broken. Scrape both.

`/metrics` is gated by default under `NODE_ENV=production`, which both packaged installs set. It
rides the same listener as `/v1`, so an install behind a reverse proxy serves it to whoever can
reach the proxy. That is the shape neither the chart's NetworkPolicy nor Compose's loopback binding
speaks to: both bound who may reach the pod or the host, and the proxy is already through.

- `METRICS_AUTH_TOKEN` is the scrape credential: a bearer token, no API key, checked on both
  processes. `install.sh` generates one into `compose/.env`; the chart mints one into the release
  Secret. `/health` and `/health/ready` on the worker's health port stay open for the probes.
- With no token set, the API's `/metrics` answers the ordinary API-key chain instead
  (`METRICS_AUTH_REQUIRED`, which defaults true under production). Set it to `false` to serve
  `/metrics` openly and restrict it at the network layer.
- The worker has no API-key chain of its own, so the token is the only gate it honours. Both
  packaged installs mint one, which is what gates both processes; on an install that sets neither,
  the worker's health port serves `/metrics` open. It is bound to loopback under Compose and
  cluster-internal under the chart, but it is not gated by `METRICS_AUTH_REQUIRED` alone.

### Where each series comes from

Every metric the engine records is emitted twice: into prom-client, which serves `/metrics` with the
bucket boundaries the code declares, and over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (which
`install.sh --with-monitoring` sets, pointing at the bundled collector). Prometheus reads the first
one. The process and runtime metrics carry the same `agledger_` prefix but go only to prom-client, so
they have one producer either way.

The OTLP copy is re-bucketed by the OpenTelemetry SDK onto its default boundaries, which run 0, 5,
10, 25 up to 10000 and are meant for milliseconds. A duration in seconds lands in the `le=5` bucket,
and a quantile over that copy then reports a fraction of 5 seconds whatever the real duration is:
p95 reads 4.75, p50 reads 2.5.

So the bundled collector drops the `agledger_*` namespace from its Prometheus exporter
(`compose/otel-collector-config.yaml`), leaving exactly one producer per series. That is what lets
every panel and rule query a metric by name with no `job=` filter, on Compose and on Kubernetes
alike, where the job label is the release's Service name.

Two things follow for your own stack. Scrape both `/metrics` endpoints and you have every
`agledger_` series; the SDK's own HTTP and PostgreSQL instrumentation exists only on the collector's
exporter, which is why the bundled Prometheus keeps scraping it.
And if you point AGLedger's OTLP export at a collector of your own that re-exports into the same
Prometheus, the two copies are not interchangeable: keep the direct `/metrics` scrape and drop or
filter the re-export, because the copy that comes back through OTLP is the re-bucketed one.

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

On Kubernetes the same three files render as ConfigMaps for the Grafana sidecar
(`--set monitoring.grafanaDashboards.enabled=true`). The chart reads them through
`helm/agledger/files/dashboards`, a symlink to the directory above, so there is one copy in the
repository and the two packaging paths cannot ship different panels.

**Overview** covers request rate, error rate and P50/P95/P99 latency by route; records created,
completions submitted, transitions by target state, verdicts by outcome and gate duration; and the
saturation set (pool total/idle/**waiting**, pg-boss queue depth, worker job throughput, vault
anchoring and integrity checks, maintenance sweep duration).

### Watching the periodic sweeps

Two worker series answer different questions about the sweeps (gate recovery, cascade cancel,
auto-rollup consistency, dispute stale, record expiry, federation DLQ recovery, partition
management, and the rest). Both live on the worker's `/metrics`, not the API's.

- `agledger_worker_jobs_processed_total{queue="maintenance"}` counts cycles. It says a sweep ran,
  and whether it succeeded. It cannot show one getting slower.
- `agledger_maintenance_sweep_duration_seconds{task="..."}` is the wall time of one sweep,
  recorded whether the sweep succeeded or threw. The `task` label is the sweep name, so a p95 per
  task separates one slow sweep from a dozen fast ones.

What to alert on is not a fixed threshold, it is the SHAPE against the population, and only for the
sweeps that take a bounded page: the recovery ones (`gate-recovery`, `cascade-cancel-recovery`,
`auto-rollup-consistency`, `federation-dlq-recovery`, `federation-pending-recovery`) and the expiry
ones (`record-expiry`, `evidence-window-expiry`). Each returns at most a batch, so its duration
should stay flat while records accumulate, and one that climbs with the record count is paying for
rows it does not return. Compare the panel against the same window's record growth before deciding
a number is high: a sweep that takes 90ms at 20 rows and 70ms at 2000 is doing exactly what it
should.

`idempotency-cleanup` belongs with them (it deletes a bounded batch too). The rest do not follow
that rule and should not be read as if they did: `rate-limit-cleanup` and
`webhook-secret-grace-cleanup` issue one unbounded statement over everything expired, so their
duration tracks how much expired since the last run, and `partition-management` is DDL that returns
no page at all. For those the useful reading is against their own history, not against the record
count.

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

`monitoring/alerts/agledger.rules.yml` ships 29 rules in five groups: silent drops, chain integrity,
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

On Kubernetes, `--set monitoring.prometheusRule.enabled=true` renders this same file as a
`PrometheusRule` for the Prometheus Operator, through the `helm/agledger/files/alerts` symlink. A
rule added here ships on both paths.

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

Both jobs need the bearer token when `/metrics` is gated:

```yaml
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/metrics-token
```

The bundled stack projects `METRICS_AUTH_TOKEN` from `compose/.env` into the Prometheus container at
that path, so the secret stays in one file. On Kubernetes,
`--set monitoring.serviceMonitor.enabled=true` writes the equivalent scrape config, reading the token
from the release Secret.
