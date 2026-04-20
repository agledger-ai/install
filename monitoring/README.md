# Monitoring

AGLedger exposes Prometheus-format metrics at `/metrics` on the API (unauthenticated by default; put a reverse proxy in front if you want to gate it).

## Grafana dashboard

The curated dashboard JSON lives at:

```
compose/grafana/provisioning/dashboards/json/agledger-overview.json
```

It auto-provisions when you run the bundled monitoring stack:

```bash
./scripts/install.sh --with-monitoring
# Grafana: http://localhost:3003 (admin / admin)
```

To import it into your own Grafana instance:

1. Copy `compose/grafana/provisioning/dashboards/json/agledger-overview.json` from this repo.
2. In Grafana, go to Dashboards → New → Import → Upload JSON file.
3. Select a Prometheus data source scraping your AGLedger `/metrics` endpoint.

## Panels included

- HTTP request rate, P95 latency, error rate, active requests
- Mandate transitions rate and verification duration
- Worker jobs processed
- Database connection pool usage
- Process memory and CPU

## Panels not yet included

The launch-readiness plan calls for adding: vault chain depth, pg-boss queue depth, and federation health panels. These will ship with a future release once the corresponding metric names on `/metrics` are finalized.

## Prometheus scrape config

Minimum scrape config:

```yaml
scrape_configs:
  - job_name: agledger-api
    metrics_path: /metrics
    static_configs:
      - targets: ['agledger-api:3000']
```

The bundled compose stack uses this config at `compose/prometheus.yml` — copy from there if you want a starting point.
