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

Every metric the engine records is emitted twice: into `@prometheus-io/client`, which serves
`/metrics`, and over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set (which
`install.sh --with-monitoring` sets, pointing at the bundled collector). Both copies carry the
bucket boundaries the code declares and the unit the metric name states, so they agree value for
value. Prometheus reads the first one. The process and runtime metrics carry the same `agledger_`
prefix but go only to `@prometheus-io/client`, so they have one producer either way.

Agreeing is not the same as being independent. Scrape the app and a collector that re-exports the
OTLP copy and every unscoped expression sums one series with its own duplicate, so counters read
double. The bundled collector therefore drops the `agledger_*` namespace from its Prometheus
exporter (`compose/otel-collector-config.yaml`), leaving exactly one producer per series. That is
what makes an unfiltered read of a metric correct: the alerting rules select these metrics by name
with no `job=` matcher at all, and the dashboard panels carry `job=~"$job"`, a template variable that
defaults to All and so selects every scrape job until an operator narrows it. Either way there is one
series per process to sum, on Compose and on Kubernetes alike, where the job label is the release's
Service name.

Two things follow for your own stack. Scrape both `/metrics` endpoints and you have every
`agledger_` series; the SDK's own HTTP and PostgreSQL instrumentation exists only on the collector's
exporter, which is why the bundled Prometheus keeps scraping it.
And if you point AGLedger's OTLP export at a collector of your own that re-exports into the same
Prometheus, pick one path per series: keep the direct `/metrics` scrape and drop or filter the
re-export, or do the reverse, but do not let both land in one Prometheus.
The shipped alert rules assume the direct scrape. `/metrics` publishes every label combination a
rule reads at 0 from process start, so `increase()` sees the first event of each series as a step
from 0 to 1. The OTLP copy records real events only, so on the re-export path a rule of the form
`increase(x[w]) > 0` misses the first event of every labelled series, and the conversion into
Prometheus can rename series the rules select by name.

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

Three worker series answer different questions about the sweeps (gate recovery, cascade cancel,
auto-rollup consistency, dispute stale, record expiry, federation DLQ recovery, partition
management, and the rest). All three live on the worker's `/metrics`, not the API's.

- `agledger_worker_jobs_processed_total{queue="maintenance"}` counts cycles. It says a sweep ran,
  and whether it succeeded. It cannot show one getting slower.
- `agledger_maintenance_sweep_duration_seconds{task="..."}` is the wall time of one sweep,
  recorded whether the sweep succeeded or threw. The `task` label is the sweep name, so a p95 per
  task separates one slow sweep from a dozen fast ones.
- `agledger_maintenance_sweep_behind_total{task="..."}` counts the cycles that stopped with work
  left. Only a sweep that bounds its own work by a clock can answer that, and today three do.
  `oidc-jti-cleanup` drains the consumed-jti register in batches for up to 30 seconds a cycle,
  every 5 minutes, against one row per admin or platform bearer accepted on a trusted issuer with
  `jtiSingleUse` set; the rows are tokens that can no longer be presented, so falling behind costs
  table size. `idempotency-cleanup` drains `idempotency_keys` on the same budget and cadence: keys
  past their TTL, which keep replaying their cached response until reached, and claims a crashed
  request left in flight, whose key answers 409 until reached. The series sits at zero on the
  cycles a sweep drains, so a flat line is a real reading rather than an absent one, and
  `AGLedgerMaintenanceSweepFallingBehind` fires on half an hour of cycles ending short. Nothing is
  lost when it does. `vault-checkpoints` is the third, and the exception: a chain a run did not reach
  has entries with no checkpoint or anchor yet. Each run goes on from where the last one stopped, and `AGLedgerVaultCheckpointsFallingBehind` fires when every run for thirteen hours
  has stopped short.
- `agledger_maintenance_unknown_task_total{task="..."}` counts ticks this worker refused because it
  carries no handler for the task. The schedules live in the database, so a job minted by a newer
  release's schedule reaches an older worker during a rollout and for as long as a rollback lasts;
  the worker fails such a job rather than completing it, so a worker that does carry the handler can
  take it. Non-zero on a settled install means the processes are older than the schedules in their
  own database: finish the upgrade, or remove the schedule if the rollback is permanent. Each
  refusal also lands on `agledger_worker_jobs_processed_total{queue="maintenance",status="failure"}`.

What to alert on is not a fixed threshold, it is the SHAPE against the population, and only for the
sweeps that take a bounded page: the recovery ones (`gate-recovery`, `cascade-cancel-recovery`,
`auto-rollup-consistency`, `federation-dlq-recovery`, `federation-pending-recovery`) and the expiry
ones (`record-expiry`, `evidence-window-expiry`). Each returns at most a batch, so its duration
should stay flat while records accumulate, and one that climbs with the record count is paying for
rows it does not return. Compare the panel against the same window's record growth before deciding
a number is high: a sweep that takes 90ms at 20 rows and 70ms at 2000 is doing exactly what it
should.

The rest do not follow that rule and should not be read as if they did: `idempotency-cleanup`
and `oidc-jti-cleanup` delete for up to a time budget, so their duration tracks the backlog until it
reaches that budget and `agledger_maintenance_sweep_behind_total` is their reading; `rate-limit-cleanup` and
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

Every panel reads through two dashboard variables at the top of each screen. **Data source** picks
which Prometheus to query, which is what lets the same file work against the bundled one, a sidecar
ConfigMap on Kubernetes and a hand import. **Job** filters by scrape job and defaults to All, which
selects every scrape job, so on a Prometheus that scrapes one install it changes nothing. It earns
its place on one that scrapes several: left at All, every panel sums them, and a rate that doubles
because a second Server started looks exactly like one that doubled because traffic did.

The bundled Prometheus keeps 30 days of series, or 10GB, whichever bound it reaches first, on the
named `prometheus-data` volume. That volume outlives the container, so a re-run of `install.sh`, an
`upgrade.sh` and a `docker compose down` all leave the history in place; only `down -v`, which is
what `uninstall.sh` runs, destroys it. A production install still points its own Prometheus at both
AGLedger `/metrics` endpoints and keeps the retention, storage and alert routing decisions with it.
See [Prometheus scrape config](#prometheus-scrape-config) for the scrape blocks to copy.

### Importing into your own Grafana

The bundled Grafana is a convenience, not a requirement.

1. Copy the JSON files above out of this repo.
2. Dashboards → New → Import → Upload JSON file.
3. Open the imported dashboard and pick your Prometheus from the **Data source** selector at the
   top of it. The import dialog does not ask: the data source is a dashboard variable, not an
   import input, so it is chosen on the dashboard and saved with it.

### Network exposure

Grafana, Prometheus, the Jaeger UI and the collector's OTLP receivers all publish on `127.0.0.1`
only, the same as the API and the database. Nothing in that stack authenticates a reader, so
reaching any of it from another host means putting it behind the reverse proxy that already
terminates TLS for the API.

## Alerting rules

`monitoring/alerts/agledger.rules.yml` ships 56 rules in seven groups: silent drops, chain integrity,
partition maintenance, federation delivery, stuck work, availability/saturation, and target
liveness.

Every rule carries a `runbook_url` annotation pointing at its own section of
`monitoring/runbooks.md`, which says what fired, what to check, what to do, and when it is safe to
silence.

The target-liveness group is the one that catches a process that is not there at all. Every other
group reads a value some process published, and an empty result is what a healthy quiet install
looks like too, so none of them can tell the two apart. Four of the five rules in the group read
engine series as well; the exception is `AGLedgerScrapeFailing`, which reads Prometheus' own `up`.
Neither packaged install leaves a stopped process reporting `up == 0`. Compose discovers both
services by DNS, and on Kubernetes the ServiceMonitor becomes operator-generated
`kubernetes_sd_configs` over endpoints; on both, a stopped Server drops out of the target list
instead. `AGLedgerApiTargetAbsent` and `AGLedgerWorkerTargetAbsent` each `absent()` a series only one
of the two processes registers, which is what makes them distinguishable without a `job=` selector
that Kubernetes would not match.

A dashboard is the wrong delivery mechanism for the silent-drop class specifically, because that
failure is defined by nobody looking. A dropped chain append or a lost audit-trail write returns
200 to the caller, logs nothing an operator will see, and shows up only as a counter that nobody is
watching at 3am. Those rules fire at `> 0` with no `for:` delay, deliberately.

Every labelled counter a rule reads through `increase()` publishes each of its label combinations
at 0 from the moment its process starts. Unseeded, a labelled series appears only at its first
increment, already at 1, and `increase()` reads that first step as 0, so a rule firing on `> 0`
would miss the first event of every series, which for a silent drop is often the only one. The
exceptions are metrics a rule reads only inside a ratio, where one missed sample does not move the
answer.

Every rule that adds several counters also wraps each term as `(sum(increase(...)) or vector(0))`,
and so does the summary tile on the silent-drops dashboard. Both halves are load-bearing. A counter
from the other process, or one whose process is not running, has no series on that target, so
`sum()` over it returns an empty vector rather than zero; adding an empty vector to anything is
empty, and the rule cannot fire. `sum()` alone fixes only the narrower case where the terms exist on
different label sets (the API and worker targets carry different `job` and `instance` values, and
PromQL arithmetic matches on the full label set). If you add a term to one of these, wrap it the
same way: the API build fails that coverage test otherwise.

The rules are unit-tested, because an alert is the one artifact whose defect is
invisible from every direction except evaluation: one that can never fire parses cleanly and loads
`health: ok`. The fixtures live in the API repo and run under `promtool test rules`. Every rule in
the file is evaluated there, each with a case that must fire and a case that must not, because a
rule that pages on the healthy reading and a rule that can never page look identical from
everywhere except evaluation.

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
rule added here ships on both paths. On that path the shipped values are adjustable without forking
the file: `monitoring.prometheusRule.overrides` takes a named alert and replaces its `severity`,
`for` or `keepFiringFor`, replaces its `expr` outright, or drops the rule with `disabled`. There is
no threshold key, because a threshold is part of the expression: retuning one means supplying the
whole `expr`. `monitoring.prometheusRule.runbookUrl` rebases every `runbook_url` onto your own copy
of the runbooks.

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
