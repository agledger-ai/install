# Alert runbooks

One section per rule in `monitoring/alerts/agledger.rules.yml`, in the order the rules appear in
that file. Every shipped alert carries a `runbook_url` annotation pointing at its section here, so
whatever surfaces the alert (Prometheus' own `/alerts` page, Alertmanager, a chat receiver) links
straight to it.

On Kubernetes the chart rewrites that base URL from `monitoring.prometheusRule.runbookUrl`, so an
install that forks this file can point every rule at its own copy without touching the rules.

Each section says what fired, what to check, what to do, and when silencing is safe. Silencing is
never the fix for a `critical`: those are all cases where the engine has already lost something or
is about to.

## Conventions

The commands below assume two variables:

```bash
AGLEDGER_URL=https://agledger.example.com
AGLEDGER_KEY=agl_plt_...     # platform-role key; /v1/admin/* requires one
```

Admin calls are `curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/..."`.
`/health` and `/health/ready` need no credential.

Logs, on Compose:

```bash
docker compose -f deploy/compose/docker-compose.yml logs --tail=200 agledger-api
docker compose -f deploy/compose/docker-compose.yml logs --tail=200 agledger-worker
```

Logs, on Kubernetes. The rendered workload names depend on your release name and
on `fullnameOverride`, so select by label rather than by name. Every object the
chart renders carries `app.kubernetes.io/instance`, and the workloads carry
`app.kubernetes.io/component`:

```bash
kubectl logs -n <ns> -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=api --tail=200
kubectl logs -n <ns> -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=worker --tail=200
```

PromQL snippets are meant for Prometheus' expression browser or `curl` against
`/api/v1/query?query=...` on your Prometheus.

## AGLedgerChainEntryDropped

An `audit_vault` append raised and the caller swallowed it, so a record transitioned with no chain
entry behind it. The chain is the product, and this gap is invisible to it: the next append takes
the next position and links to the surviving head, so neither this Server's scan nor an offline
verifier reports a break. This alert and the record's own history (a transition with no entry behind
it) are the only evidence, and no later write reconstructs the missing entry.

Check:

```promql
increase(agledger_federation_audit_vault_dropped_total[1h])
```

and the API log around that window for the append error. Then size the damage:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/scan"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/scan/<jobId>"
```

Do: the append failure is almost always the database refusing the write. Missing partition runway on
`audit_vault`, a revoked GRANT, a full disk and a dead connection all land here, so check
`AGLedgerPartitionRunwayExhausted` and `AGLedgerDbConnectionsDropping` before anything else. The
entries themselves cannot be backfilled, and no verification will fail over them; record the affected
range so the gap has an explanation when a record's transitions are compared with its chain.

Silence: never. Every firing is a permanent gap in the chain.

## AGLedgerAuditTrailDropped

A state change committed and the event row recording it did not. `/v1/events` and anything polling
it are missing rows for the window, while the records themselves are correct.

Check which of the six counters moved, since they have different causes:

```promql
{__name__=~"agledger_(post_commit_callback_failures|federation_outbound_event_persist_dropped|cascading_gate_persist_event_failures|phase2_enqueue_persist_event_failures|federation_forensic_audit_dropped|support_bundle_audit_failures)_total"}
```

Then the API and worker logs for the write error behind it.

Do: these are all post-commit paths, so the database was reachable enough to commit and not to
insert. A statement timeout, a partition gap on `events` or `system_audit_log`, or a pool with no
free client are the usual three. Fix the database condition; the events are not recoverable, so tell
any consumer replaying from `/v1/events` that the window is short.

Silence: no. Downgrade only if you have confirmed the cause is a one-off and the affected window is
recorded somewhere an auditor will find it.

## AGLedgerWorkEnqueueDropped

An enqueue failed and was swallowed. The work will never run. Cascade-cancel is the sharpest of the
six: a child record keeps executing after its parent terminalized.

Check which counter moved, then the queue itself:

```promql
increase(agledger_cascade_cancel_enqueue_failures_total[1h])
increase(agledger_webhook_enqueue_failures_total[1h])
max by (queue, state) (agledger_pgboss_queue_size)
```

Do: pg-boss writes to the same database as everything else, so an enqueue failure is a database
failure in almost every case. Once the database is healthy, the recovery sweeps re-drive most of
this on their own: gate recovery and cascade-cancel recovery run every two minutes, federation
pending recovery likewise. What they do not cover is webhook dispatch, so check
`GET /v1/admin/webhook-dlq` and re-drive with `POST /v1/admin/webhook-dlq/retry-all` if deliveries
are missing.

Silence: no.

## AGLedgerGateJobRetriesExhausted

A gate-worker job was queued, ran, and gave up after exhausting its retries. Two counters feed this:
a cascade rollup that ran out of retries on the last child's job, and a lost DLQ advisory pass.

Check whether the consistency sweep is rolling up the parents the rollup did not (the rollup only
ever fails a parent, or expires one past its own deadline; children never settle one):

```promql
increase(agledger_auto_rollup_stuck_parents_total[1h])
increase(agledger_auto_rollup_repaired_parents_total[1h])
```

Do: if repaired keeps pace with stuck, the sweep is doing its job and no action is needed. It rolls
up a parent five to ten minutes after its tree goes quiet. If stuck climbs and repaired does not, read
the worker log for the repair error and look for a parent left `ACTIVE` with every child terminal and
one of them failed. A
lost advisory pass is not repairable: the record is correctly awaiting its principal and only the
advisory annotation is gone.

Silence: up to a week, if the sweep is keeping pace and the rollup failures are traceable to a
database incident you have already fixed.

## AGLedgerSiemExportDegraded

The SIEM feed is lossy. Four counters feed this and three of them mean rows that will not arrive.

Check which one moved:

```promql
increase(agledger_siem_mapper_failures_total[1h])
increase(agledger_siem_http_batches_dropped_total[1h])
increase(agledger_siem_file_lines_dropped_total[1h])
increase(agledger_siem_poll_failures_total[1h])
```

`agledger_siem_poll_failures_total` is the one that is not loss: the cycle threw before the cursor
moved, so the next cycle re-reads the same rows. The other three are. A mapper failure means the row
would not serialize, so the poller counts it, skips it and advances the cursor past it; nothing
re-reads it. Dropped HTTP batches and dropped file lines are the buffered bus path losing what it
held. A sink that refuses a polled batch is a fourth thing and is deliberately not in this rule: the
cursor is held, the rows are re-read next cycle, and it surfaces as
`agledger_siem_poll_delivery_retries_total` and eventually `AGLedgerSiemPollerFallingBehind`, or, if
the collector refused the request rather than failing to take it,
`AGLedgerSiemCollectorRejecting`.

Do: for HTTP drops, check the collector at `SIEM_HTTP_URL` and the credential in
`SIEM_HTTP_AUTH_HEADER`. For file drops, check that `SIEM_FILE_PATH` is writable and its filesystem
is not full. For mapper failures, the worker's log names the event type that would not serialize:
the worker is the process that drains the push sinks. What the bus path
dropped is still in `events` and `system_audit_log`, so a pull-mode collector can re-read it from
`GET /v1/siem/stream`, which pages the same rows.

Silence: not while any of the three loss counters is moving. A firing driven by
`agledger_siem_poll_failures_total` alone, during a database incident you have already fixed, can
wait a few hours.

## AGLedgerSiemCollectorRejecting

The SIEM HTTP collector is answering on the request's own terms rather than failing to take it. It
will not clear by waiting.

Nothing is lost. The cursor does not advance past a refused batch, the rows stay in `events` and
`system_audit_log`, and delivery resumes from the same position once the configuration is fixed.
What is lost is detection latency, for as long as it takes.

The Server logs the collector's own reply at ERROR, once per state change rather than once per
attempt. That line is the fastest answer:

```bash
docker compose logs agledger-worker | grep "SIEM collector rejected"
```

By status:

| Status | Usual cause |
|---|---|
| 400 | The body shape. Splunk's `/services/collector/event` answers `{"text":"No data","code":5}` to bare NDJSON: set `SIEM_HTTP_MODE=hec`, or point `SIEM_HTTP_URL` at `/services/collector/raw?sourcetype=_json` instead. |
| 401, 403 | The credential in `SIEM_HTTP_AUTH_HEADER`, or an HEC token that is disabled or not allowed on the index in `SIEM_HTTP_HEC_INDEX`. |
| 404 | `SIEM_HTTP_URL`. Under `SIEM_HTTP_MODE=hec` the Server appends `/services/collector/event` only when the URL names no collector path. |
| 413 | The collector's own body limit against `SIEM_BATCH_SIZE` times `SIEM_MAX_EVENT_BYTES`. Lower the batch size first. |
| 422 | A collector that parses the documents it is sent and refused one. The Server's log carries its reply. |

The poller backs off to its 60s ceiling on these rather than climbing the doubling ladder, so a fix
takes up to a minute to show. `agledger_siem_poll_delivery_retries_total{sink="http"}` keeps moving
alongside this counter; that one also moves for a collector that is simply down, which is the
distinction this alert exists to make.

Silence: only with the collector's operator, and only for as long as the fix takes. Rows accumulate
behind the held cursor the whole time.

## AGLedgerSiemPollerFallingBehind

The oldest audit row the poller has not forwarded is over five minutes old. Detection latency on auth
failures, scope denials and credential changes is at least that. Nothing is lost: a backlog defers
rows rather than dropping them.

The rule reads each process's lag only while that process keeps measuring it, which it does on every
poll cycle that holds the cursor: `agledger_siem_poll_lag_updated_timestamp_seconds` says when it
last did. A process that stops winning the cursor stops alerting even though its gauge still shows
the old reading, so compare that stamp against `time()` before trusting a raw gauge on a dashboard.

Check, in this order:

```promql
sum by (sink) (increase(agledger_siem_poll_delivery_retries_total[15m]))
increase(agledger_siem_poll_skipped_total[15m])
increase(agledger_siem_poll_ahead_rows_total[15m])
```

and the oldest transaction on the database:

```sql
SELECT pid, usename, state, now() - xact_start AS age, left(query, 80)
  FROM pg_stat_activity
 WHERE datname = current_database() AND xact_start IS NOT NULL
 ORDER BY xact_start LIMIT 5;
```

Do: a sink refusing the batch is the common cause and shows up in the retry counter. If instead the
oldest transaction's age tracks the lag, that transaction is holding the visibility watermark back
and the poller is fine. `pg_dump` does this for the length of a backup, and so does a long analytics
query or a forgotten `psql BEGIN`. End it, or wait: export resumes on its own. Past
`SIEM_MAX_HOLDBACK_SECONDS` (default 60) the live tail is delivered from above the watermark anyway,
which is what `agledger_siem_poll_ahead_rows_total` counts.

Silence: for the length of a scheduled backup window. Not otherwise.

## AGLedgerSiemPollerStatsBlanked

The poller is running on a role without `pg_read_all_stats` while another role holds a write
transaction on the same database. Postgres blanks that transaction's `xact_start`, so the poller
cannot prove which rows are visible. It halted rather than page over them.

Check the role and its grants:

```sql
SELECT current_user, pg_has_role(current_user, 'pg_read_all_stats', 'member');
```

Do: grant it.

```sql
GRANT pg_read_all_stats TO agledger_app;
```

Or point `DATABASE_URL` at a role that already has it. Until then the halt holds for as long as
another role keeps a write transaction open. A halted cycle still takes the cursor row and still
measures the backlog behind it, so `agledger_siem_poll_lag_seconds` climbs through the halt and
`AGLedgerSiemPollerFallingBehind` fires once it passes five minutes. Expect both alerts, and read
this one as the cause of the other.

Silence: never while it is firing. This is the one SIEM condition that loses rows invisibly if the
poller does not halt.

## AGLedgerSiemStreamHalted

`GET /v1/siem/stream` answered 503 because it could not compute the visibility watermark it pages
against. Collectors pulling this endpoint are not ingesting, and they know it: the halt is loud on
their side too. The `reason` label has three values and says which of them this is.

Check:

```promql
sum by (reason) (increase(agledger_siem_stream_halted_total[1h]))
```

Do: for `track_activities_off`, set `track_activities = on` in `postgresql.conf` and reload. For
`stats_blanked`, grant the Server's role `pg_read_all_stats` as in the section above. `unreadable` is
neither: the one-row watermark query over `pg_stat_activity` came back with no row at all, which is
the connection answering something the engine does not understand rather than a setting being wrong.
Run that query by hand on `DATABASE_URL` and look at what sits between the Server and Postgres, a
pooler or proxy first. Confirm with:

```bash
curl -sS -i -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/siem/stream?limit=1"
```

The push poller runs in the WORKER, and only with a sink configured. An install that pulls only from
`GET /v1/siem/stream` runs no poller, so this is the only SIEM alert it can get and
`AGLedgerSiemPollerStatsBlanked` stays silent on it. With `SIEM_ENABLED=true` and either
`SIEM_FILE_ENABLED` or `SIEM_HTTP_ENABLED` on, the worker polls, and on the `stats_blanked` cause the
two alerts fire together.

Silence: no.

## AGLedgerSiemStreamWatermarkStalled

The pull stream's visibility ceiling has been more than ten minutes behind for ten minutes, so the
route is serving well-formed empty pages while rows accumulate. A collector cannot tell that from
"caught up". Rows are withheld, not lost.

Only a stream request reads the ceiling, so the rule sees a replica only while collectors are pulling
it, and `agledger_siem_stream_watermark_updated_timestamp_seconds` says when that last happened. A
replica the collectors stopped reaching keeps its last reading on the gauge but drops out of the
alert.

Check the oldest transaction, which is what holds the ceiling:

```sql
SELECT pid, usename, state, xact_start, left(query, 80)
  FROM pg_stat_activity
 WHERE xact_start IS NOT NULL
 ORDER BY xact_start LIMIT 5;
```

Do: the watermark is `min(xact_start)` over every backend with no write filter, so a read-only
transaction holds it just as hard as a writer. `deploy/scripts/backup.sh` keeps one open for the
whole dump, and a long anti-wraparound vacuum or an idle-in-transaction `psql` does the same. End the
transaction and export resumes. If it is a backup, it will end on its own.

Silence: for the length of a scheduled backup or vacuum window.

## AGLedgerSiemStreamStatsRestricted

Some same-database backends are invisible to the Server's role. This is the pre-failure signal, not a
failure: `GET /v1/siem/stream` serves correctly while those backends stay read-only and halts with
503 the moment one writes.

Check:

```promql
agledger_siem_stream_blanked_backends
```

Do: grant `pg_read_all_stats` to the Server's role. It is a standing configuration fact rather than
an event, so it will keep firing until you do, on every replica collectors keep pulling. Only a
stream request measures the count, so a replica the collectors stopped reaching drops out of the
alert while its gauge keeps the old value; `agledger_siem_stream_watermark_updated_timestamp_seconds`
says when it last measured.

Silence: reasonable for as long as it takes to schedule the grant, and only if you know the other
backends are read-only (a monitoring role, a read replica's feedback connection). Once one of them
can write, this is a pending outage.

## AGLedgerSiemPollerStatsRestricted

The same condition on the push channel's gauge. The poller's role cannot see some backends on its own
database. Export is correct while they stay read-only and halts as soon as one writes.

Only a poll batch that holds the cursor measures the count, and
`agledger_siem_poll_blanked_backends_updated_timestamp_seconds` says when that last happened on each
process. A process that stops winning the cursor drops out of the alert while its gauge keeps the old
value.

Check:

```promql
agledger_siem_poll_blanked_backends
```

Do: grant `pg_read_all_stats` to the role in `DATABASE_URL`.

Silence: same terms as `AGLedgerSiemStreamStatsRestricted`.

## AGLedgerRateLimitStoreFailing

`@fastify/rate-limit` is configured with `skipOnError`, so a store query that throws lets the request
through. Rate limiting is off and every symptom of it being on is absent: no 429s, no errors, no
latency change. This counter is the only thing that says so.

Check the API log for the store error, then:

```promql
increase(agledger_rate_limit_store_failures_total[1h])
increase(agledger_rate_limit_exceeded_total[1h])
```

A store failing while `exceeded` sits flat at zero is the signature.

Do: with `RATE_LIMIT_STORE=postgresql` the usual three causes are a missing `rate_limits` table, a
missing GRANT on it, and the table sitting in a schema off the `search_path`. Confirm with
`\dt rate_limits` on the app role. Setting `RATE_LIMIT_STORE=memory` restores limiting per process
as a stopgap, at the cost of per-replica counting.

Silence: no. An unthrottled public API is the exposure here.

## AGLedgerProvisioningErrors

The last provisioning run on at least one API replica did not load or apply the whole
`PROVISIONING_CONFIG_PATH` directory. What it could read was applied; what it could not is missing
from the running install, and the Server serves without it; `GET /v1/admin/system-health` reports
the load errors in `degradedReasons`. `stage="load"` is a file that did
not parse (commonly a `${VAR}` reference with no default) or an entry that failed validation, and
while it is non-zero prune is suppressed. `stage="reconcile"` is a parsed resource that failed to
apply.

Check what failed:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/provisioning/status"
```

Do: fix the files, then `POST /v1/admin/provisioning/reload`. The reload runs on the one API replica
that takes the request, and each replica reports its own last run, so send `SIGHUP` to the others or
restart them to clear their readings.

Silence: while a known file is being fixed.

## AGLedgerCacheInvalidationListenerDown

One process's LISTEN session for cache invalidation has been down for five minutes. Every replica
broadcasts its cache changes on it: an API key revoked, a signing key retired, a chain rewind
detected or acknowledged, a rate-limit exemption added or removed. The process the alert names
hears none of them, and serves each cache until it expires or is re-read on its own cadence
(the API-key cache's TTL, the rewind state's periodic re-read, the signing-key watch). The runtime
rate-limit exemption set has no expiry, so that replica keeps the set it had until the session is
back. The process retries the connection every few seconds on its own.

Check the process's own report and the failed attempts:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/system-health"
```

```promql
sum by (instance) (increase(agledger_pg_listener_reconnect_failures_total[15m]))
```

The log line on each failed attempt is `Failed to start pg LISTEN`, with the driver's error.

Do: the session needs a direct, session-mode connection. Where a transaction-mode pooler sits in
front of the database, `DATABASE_URL_DIRECT` has to name the database itself; check that it does
and that the database accepts another connection (`max_connections`). Once the session is back,
every cache that only a broadcast would change is dropped or re-read on that process: the API-key,
account and cert caches, the schema registry, the key trust walk, trusted-issuer keys, `llms.txt`
and the rewind state. The rate-limit exemption set is rebuilt from `RATE_LIMIT_EXEMPT_OWNERS` and
the exemption changes recorded since the process started, which is the set it would hold had it
heard every broadcast. Nothing needs a restart.

Silence: during a database maintenance window that drops connections.

## AGLedgerConfigReloadFailing

A config reload or cache refresh is failing, so the running configuration may not match what is on
disk and replicas may be serving stale schemas. The operator edited a file, saw no error, and is
running something else.

Check which of the five moved, then the matching surface:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/provisioning/status"
```

Do: for provisioning failures, that endpoint reports the parse or apply error against
`PROVISIONING_CONFIG_PATH`; fix the YAML and re-run
`POST /v1/admin/provisioning/reload`. For `llms.txt` customization failures, check the file named by
`AGLEDGER_LLMS_TXT_OVERRIDE_PATH` (or the prepend and append paths) is readable and under the 128 KB
cap, then `POST /v1/admin/discovery/reload`. For schema warm-cache failures,
`POST /v1/admin/schemas/cache/flush` re-warms. Cache-invalidation drops are invalidations that
arrived and could not be applied (a local handler threw, a NOTIFY could not be sent, a payload
did not parse or named a type this release does not know); a LISTEN connection that is down
receives nothing and is `AGLedgerCacheInvalidationListenerDown` instead. An exemption rebuild
failure is a process that reconnected its LISTEN session and could not read the exemption changes
made meanwhile (the log line names the error): `GET /v1/admin/rate-limit-exemptions` on that
replica may lack a change made elsewhere; re-issue it, or restart that process.

Silence: a few hours, if you have confirmed which config is stale and that it does not matter yet.

## AGLedgerOidcJtiReplayBurst

Single-use admin OIDC bearers are being presented a second time. These tokens VERIFIED: the
signature, the issuer, the audience and the expiry were all good, and the refusal is that this
Server has already seen that `jti`. So a real credential from a trusted IdP is being reused, by the
client that holds it or by somebody who captured it.

Check who and from where:

```promql
sum by (reason) (rate(agledger_oidc_admin_jti_replays_total[10m]))
```

then the paired audit rows, which carry the issuer, the subject and the source address. The stream is
NDJSON and takes no event-type filter, so the selection is jq's:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/siem/stream?format=raw&limit=500" \
  | jq -c 'select(.type == "auth.failed" and (.payload.reason | startswith("oidc_jti")))'
```

Read `payload.surface`: `cert_exchange` means the
token was replayed at `POST /v1/auth/oidc/cert`, `delegated_on_behalf_of` at the delegation header,
and its absence means the admin bearer path.

Do: if the subject and address match a client you run, that client is holding one token across
requests. Either fix it to mint a token per request, or clear `jtiSingleUse` on that
`trusted_issuers` row (`PATCH /v1/admin/trusted-issuers/{id}` for an admin-managed row; edit the
provisioning YAML and reload for a managed one). If the address is not one you recognise, treat the
token as captured: revoke it at the IdP, and revoke the certs it minted with
`POST /v1/admin/trusted-issuers/{id}/revoke-certs`.

A `reason` of `jti_unregistrable` is not a replay. It means the register refused the write because
the `jti` was oversized, which is a client or IdP defect; the bearer is still refused, because
single use cannot be proven.

Silence: while a known client is being fixed, and only if you have confirmed the source address.

## AGLedgerOidcSingleUseUnenforceable

A `trusted_issuers` row has `jtiSingleUse` set and is admitting every presentation anyway, because
the tokens it validates carry no id to register. The flag is on and enforcing nothing, which is worse
than off: `AGLedgerOidcJtiReplayBurst` above sits at zero and reads as healthy.

The id is the token's `jti` claim, or the claim the row names under the `claimMapping` logical name
`jti`, with the standard `jti` winning when both are present. Okta and Keycloak mint `jti` by
default. Entra ID never does, on an access or an ID token, and has no setting that adds one; it mints
`uti`. Auth0's default access-token profile mints neither. A Google service-account ID token has no
per-token id under any name.

Find which row:

```promql
sum by (role) (increase(agledger_oidc_admin_jti_unenforceable_total[1h]))
```

The counter is not labelled by issuer, because an IdP can present unbounded distinct values. The
engine log carries the row id once per row per process, on the line
`trusted_issuers row has jti_single_use set but this token carries no jti`:

```bash
kubectl logs -l app.kubernetes.io/name=agledger --since=24h \
  | jq -c 'select(.msg | startswith("trusted_issuers row has jti_single_use set"))
           | {issuerId, iss, role}'
```

Then read the row and its mapping:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/admin/trusted-issuers" \
  | jq -c '.data[] | select(.jtiSingleUse) | {id, issuerUrl, appliesTo, claimMapping}'
```

Do: one of three, and all of them are a `PATCH /v1/admin/trusted-issuers/{id}` (or an edit to the
provisioning YAML plus `POST /v1/admin/provisioning/reload` for a managed row).

- The IdP mints an id under another name. Add it: `{"claimMapping": {"jti": "uti"}}` for Entra ID,
  merged with the mapping the row already carries. The same mapping also makes `POST
  /v1/auth/oidc/cert` single use per that claim on rows serving the agent door, which is the
  intended effect.
- The IdP can be made to mint a `jti`. On Auth0 that is switching the API to the RFC 9068
  access-token profile. Nothing on this Server changes.
- Neither is available. Clear the flag: `{"jtiSingleUse": false}`. The bearer stays reusable until
  its `exp`, which is what it already was, and the row now says so.

Silence: only while one of the three changes is being made. A permanent silence here is a row
documenting a control it does not have.

## AGLedgerOidcSubjectRefusalBurst

Tokens that verified against a registered trusted issuer are being refused because their subject is
not on that issuer's `subjectAllowlist`. One refusal is the control working: somebody's access was
pulled and their token stopped working. A burst is one of two other things, and they need different
answers.

Check which door and which subject:

```promql
sum(increase(agledger_oidc_admin_subject_refusals_total[15m]))
sum by (reason) (increase(agledger_oidc_cert_exchange_refusals_total[15m]))
sum by (reason) (increase(agledger_oidc_delegation_refusals_total[15m]))
```

then the subjects, from the audit rows carrying `payload.reason = oidc_subject_not_allowlisted`:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/siem/stream?format=raw&limit=500" \
  | jq -c 'select(.type == "auth.failed" and .payload.reason == "oidc_subject_not_allowlisted")
           | {sub: .payload.sub, iss: .payload.iss, surface: .payload.surface}'
```

Do: if the subjects are principals you expect to have access, the allowlist on that row is behind
the IdP. Read the row with `GET /v1/admin/trusted-issuers`, then add them with `PATCH
/v1/admin/trusted-issuers/{id}`, or clear `subjectAllowlist` entirely if the row was never meant to
be restricted. If the subjects are not ones you recognise, the IdP is issuing tokens for principals
this Server was never told about: that is a question for whoever administers the IdP, and the
allowlist is doing its job in the meantime.

A refusal on the delegation counter with `reason = delegation_actor_binding_mismatch`, or on the
cert exchange counter with `reason = cert_agent_binding_mismatch` (a verified token whose exchange
named an agent the token does not bind to), is a different event and does not belong to this alert:
see the CRITICAL severity those reasons carry on the SIEM feed.

Silence: a few hours while the allowlist is being brought up to date.

## AGLedgerVaultIntegrityCheckFailed

The daily integrity check verified a sample of chains, the record-less chains, the read log and
the key registry's trust walk, and one of them did not verify. The worker log line `Vault integrity
check found broken chains` lists each failure in `errors`; a `key registry` entry there is a
registry finding rather than a chain break. A `key registry standing` entry is listed but not
counted, and never fires this alert on its own: a standing finding is one no setting clears whose
remedy has been carried out (a retired row's `retired_at` that differs from its signed retirement,
or a later admission a leaked key signed once it is distrusted from an instant no later than that
admission and retired with force), so it stays as the record of what happened.

Do not restart into this. Capture the state first:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/scan"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/scan/<jobId>"
```

and take a database backup before any remediation.

Each entry under `brokenRecords` (and `globalChains.brokenChains`) names the break at `brokenAt` and
`reason`. An entry that also carries `firstFinding` has an earlier key-window or unsupported-algorithm
entry, which is what an offline verifier reports first; the break that matters is still the one at
`brokenAt`. A `reason` of `signing_key_unanchored` means the entry was signed by a key no key
statement links to a key held outside the database: a row written into `vault_signing_keys`
directly, or a key a forced retirement left unanchored. The scan's `keyRegistry` block lists such keys in
`unanchoredKeyIds` (not a failure by itself), and its `findings` (`key_statement_invalid`,
`key_closure_invalid`, `key_window_drift`) fail `healthy` unless they carry `standing: true`.

Do: work out whether the break is a missing entry or a modified one. A missing entry usually has
`AGLedgerChainEntryDropped` in its history; a modified one does not, and means something wrote to
`audit_vault` outside the engine. Compare against the signed checkpoints, which are anchored
independently:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/audit-vault/checkpoints"
```

A `reason` of `key_expired` or `key_not_yet_active` is a key-window break, not a modified entry:
the entry is intact and signed, but by a key outside the window the Server publishes for it. See
`AGLedgerVaultKeyWindowViolation` below.

Silence: never.

## AGLedgerVaultKeyWindowViolation

A chain carries an entry signed outside the published `[activatedAt, retiredAt]` window of the key
that signed it. The chain is still checkpointed, so the integrity check can read clean, but an
offline verifier fails every export carrying the entry with `CHAIN_KEY_EXPIRED` or
`CHAIN_KEY_NOT_YET_ACTIVE`. Run a scan and read each broken chain's `reason` and `brokenAt`:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/scan"
```

Two causes:

- A process kept signing after its key was retired: an api or worker replica that missed the
  rotation. GET /health on each replica names the key it holds; restart the one on the old key.
- `VAULT_DISTRUSTED_KEYS` names a key with an `@<instant>`. The leaked key's window ends at that
  instant, so nothing it signed from then on verifies, honest entries included (a `RESTORE_EPOCH`
  the key signed as an acknowledgement among them). What it signed from the instant until a key you
  trust retired it is counted with `reason="signing_key_distrusted"`: the scan lists those entries
  under `distrustedEntries` as accounted for rather than broken, and the counter keeps rising on
  each checkpoint cycle of a chain that carries one, because each is a write under a key you say
  leaked. Compare each entry's time and signing key with the instant and the retirement. An entry
  it signed after that retirement is `reason="key_expired"` and a broken chain in the scan: the key's
  private half is still in use against this database. Nothing re-signs them; what the operator
  controls is that no further entry is signed under that key, which the restart onto the new key
  and its forced retirement already ensure.

Silence: for the second cause, `reason="signing_key_distrusted"` once every listed entry is
accounted for against the instant; never for a `key_expired` entry written after the retirement.

## AGLedgerVaultSignerUnreachable

The vault signing key is held in AWS KMS (`VAULT_SIGNING_KEY_KMS_ARN`) and a process has stopped
signing because consecutive Sign calls failed. That process answers 503 on every write and on
`/health/ready`, so a load balancer routes around it. A worker stops fetching jobs and puts back
any it fetched but had not started, so they wait in the queue rather than fail. It reopens on its own: every signing-key watch tick makes one probe Sign, and the
first answered one resumes writing.

Check, from the affected process:

```bash
curl -sS "$AGLEDGER_URL/health"
# signingKey.gate "signer_unreachable"; the worker also reports jobConsumption "held_signer_unreachable"
```

and the process log, where each failed call names the AWS error. The usual causes are, in order:
the KMS endpoint unreachable from the pod (a VPC endpoint policy, a security group, DNS), the key
disabled or pending deletion (`KMSInvalidStateException`), and the role missing `kms:Sign`
(`AccessDeniedException`).

Do: fix the cause. Nothing on the Server needs restarting; the watch reopens the gate. If the key
is only disabled, re-enable it long enough to stage a new KMS key the usual way: the new ARN,
`VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN` set to the old one, a restart, then retire the old key id
from a process on the new key. If it is gone for good, nothing can sign the succession: set
`VAULT_TRUST_ANCHORS` to the pins of the keys whose history you vouch for (the old key's among
them), set the new ARN and restart, and the new key registers under a fresh genesis whose pin you
give to auditors. Without that the new process reports `signingKey.gate` `unanchored` and signs
nothing.

Silence: never. A process in this state writes nothing.

## AGLedgerVaultRemoteSignFailing

Individual KMS Sign calls are failing without tripping the gate above. Each failure is either one
write answered 503 to its caller, retryable, or a failed probe of the signing-key watch, which signs
once each watch interval on every api and worker process whether or not anything is written.

Check the process log for the AWS error name on the failed calls, and the latency histogram:

```promql
histogram_quantile(0.99, sum(rate(agledger_vault_remote_sign_seconds_bucket[5m])) by (le))
```

`ThrottlingException` means the account's KMS Sign quota for the key type, which is shared with
every other caller in that account and region. `VAULT_SIGNING_REMOTE_MAX_PER_SECOND` caps each
process; the sum across api and worker replicas is what has to sit under the quota, and the quota
itself is raised through AWS Service Quotas. A rising p99 with no errors is the path to KMS, and
every chain append holds its transaction open for that long.

Silence: while a quota increase is pending, if the failure rate is one you accept.

## AGLedgerVaultAnchorsNotLanding

Checkpoints are being written but their S3 anchors are not landing, and each checkpoint run's retry
has failed for over two intervals. Nothing is lost while they wait: the checkpoints are in the
database and stay queued in `vault_anchor_pending` until an upload succeeds. But until one does,
the entries they cover have no evidence outside the database, which is the one layer a privileged
database user cannot rewrite.

Check how many, how old, and what the store said:

```promql
max(agledger_vault_anchor_pending)
max(agledger_vault_anchor_pending_oldest_age_seconds) / 3600
sum by (outcome) (increase(agledger_vault_anchor_upload_total[6h]))
```

```sql
SELECT attempts, last_attempt_at, last_error FROM vault_anchor_pending ORDER BY created_at LIMIT 5;
```

Do: `last_error` names the failure. The usual ones are credentials the worker no longer has, a
bucket policy or Object Lock setting that refuses the write, and egress to the endpoint. Fix it, and
each checkpoint run retries the queue, least recently tried first, for 10 seconds before it writes
new checkpoints; a large backlog drains over several runs, and a shorter
`VAULT_ANCHOR_INTERVAL_MINUTES` brings them sooner. A run that finds the store still failing stops
asking it until the next run, and queues what it writes.

Turning anchoring off stops the retries and this alert; the queue is kept, and is retried once
anchoring is back on.

Silence: while a known store outage is being fixed. Never otherwise.

## AGLedgerChainWritesRefused

External anchors put this database behind a chain position it had already anchored, which is what a
restore to an earlier backup leaves behind, and the Server has stopped writing to the chain. Records,
completions, verdicts, schema registrations and SCITT registrations answer `409` with
`reason: CHAIN_REWIND_DETECTED`. The next entry would take a position the lost history already
signed and delivered, and both copies would verify, so the Server waits for a person.

Check the evidence and which anchor check found it:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/vault/rewind"
```

Do: find out what left this Server after the backup the database was restored from: webhook
deliveries, the SIEM stream of `system_audit_log`, Settlement Signals, and federation peers. The
"What none of this detects" list in the deploy README says where each can disagree. Then
acknowledge with a note saying what you reconciled; it is written onto the chain and cannot be
edited afterwards:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" -H "Content-Type: application/json" \
  -d '{"note":"<what was reconciled, by whom>"}' "$AGLEDGER_URL/v1/admin/vault/rewind/acknowledge"
```

Writes resume on every replica within 30 seconds, and a `RESTORE_EPOCH` entry marks where the two
histories part.

A replica that could not re-read the state after a change broadcast also reads 1, until a read
succeeds. If `GET /v1/admin/vault/rewind` shows nothing open, check that replica's database
connection instead.

Silence: never.

## AGLedgerCheckpointSkippedBrokenChain

Checkpointing found a record whose chain does not verify and refused to anchor over the break. Every
write on that chain after this point is unanchored until the break is resolved.

Check:

```promql
increase(agledger_vault_checkpoint_skipped_broken_total[24h])
```

and the worker log, which names the record.

Do: this is `AGLedgerVaultIntegrityCheckFailed` reached from the other direction, so follow that
section. Checkpointing resumes on its own once the chain verifies again. Until then, the
tamper-exposure window on that chain keeps growing: entries written since the last anchored
checkpoint have no external evidence.

Silence: never.

## AGLedgerPartitionMaintenanceFailing

The daily partition-management job (02:00 UTC) could not extend at least one partitioned table, or
could not refresh the runway gauges afterwards. Runway is draining on whatever failed, and the gauges
may be reporting the last healthy reading.

Check the worker log first, because it is what tells the three cases apart. A single table that could
not be extended is logged with its name and the Postgres error. A call that failed outright, on a
lock wait or a lost connection, is logged without a table name and means no table gained runway at
all. A gauge-refresh failure is logged separately.

Then read the real runway from the database rather than the gauge:

```sql
SELECT table_name, runway_days, default_rows FROM partition_runway();
```

Do: refill by hand once the cause is fixed. Take the sweep's advisory lock first, so a hand refill
that lands on the 02:00 job cannot run the same CREATE TABLE twice and report a failure that is not
one. Waiting rather than trying, because a person at a prompt wants the refill done, not skipped:

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('partition-management'));
SELECT * FROM ensure_future_partitions(3);
COMMIT;
```

A lock wait is the common failure: the call needs ACCESS EXCLUSIVE on four partitioned parents and
gives up after 30 seconds rather than queueing ahead of every reader.

Silence: no. This is the alert the gauges cannot substitute for.

## AGLedgerPartitionMaintenanceSkipped

The daily job has run and done nothing at least twice in 49 hours, because another copy of the sweep
held its advisory lock both times. Nothing failed. The skipped cycle still refreshes the runway
gauges and stamps their freshness, so `AGLedgerPartitionMaintenanceFailing` and
`AGLedgerPartitionMaintenanceNotRunning` both read healthy while no partition is being created, and
the next signal without this rule would be `AGLedgerPartitionRunwayLow` about two months later.

One skip is the guard working: a pg-boss lease retry arriving while the original cycle is still going
is exactly what the lock absorbs. Two across consecutive daily ticks is not, because the lock is
transaction-scoped and a healthy cycle takes seconds. What spans two ticks is a backend wedged inside
`ensure_future_partitions()`, where `statement_timeout` is deliberately 0 and the session is never
idle in transaction, so neither database timeout ends it.

Find the holder:

```sql
SELECT a.pid, a.state, a.wait_event_type, a.wait_event,
       now() - a.xact_start AS in_xact, left(a.query, 120) AS query
  FROM pg_locks l
  JOIN pg_stat_activity a ON a.pid = l.pid
 WHERE l.locktype = 'advisory'
   AND l.objid = hashtext('partition-management')::oid
 ORDER BY a.xact_start;
```

Read `in_xact` and `wait_event` together. A session hours into its transaction and waiting on a
relation lock is blocked by a long-running reader of one of the four partitioned parents; a session
hours in with no wait event is the worker process itself, stalled after the statement returned.

Do: fix what it is waiting on rather than killing it, where there is something to fix. Where there is
not, `SELECT pg_terminate_backend(<pid>);` ends the transaction and releases the lock, which costs
nothing here: the sweep is idempotent and the next tick recreates whatever the killed one had not.
Then refill by hand with the snippet in `AGLedgerPartitionMaintenanceFailing` above, and confirm with
`SELECT table_name, runway_days FROM partition_runway();`.

If nothing holds the lock and the alert is still firing, the skips are in the past and the counter is
still inside its 49-hour window; it clears itself once two clean ticks have gone by.

Silence: no. Every other partition rule reads healthy through this state, which is why it exists.

## AGLedgerPartitionMaintenanceNotRunning

The daily job has not refreshed the runway gauges for over 36 hours, or they are absent entirely. The
job is not failing, it is not running. Each worker also re-reads the gauges every 10 minutes, so their
readings are current; what this says is that nothing is creating partitions.

Check that the worker is up and that its schedule still holds the entry:

```sql
SELECT name, key, cron, timezone FROM pgboss.schedule ORDER BY name, key;
```

The `key` column is what carries `partition-management`; `name` is the maintenance queue every
scheduled task shares. Then:

```bash
docker compose -f deploy/compose/docker-compose.yml ps agledger-worker
```

Do: every worker boot queues one partition-management run, so a restarted worker publishes the
gauges within minutes. If they are still absent or stale, either the worker is down (see
`AGLedgerWorkerTargetAbsent`), the run is failing (see `AGLedgerPartitionMaintenanceFailing` and
the worker log), or its pg-boss schedule lost the `partition-management` entry, which a restart
re-registers. Confirm the real runway
with `SELECT * FROM partition_runway();` before deciding how urgent it is.

Silence: through a planned worker outage. Not otherwise.

## AGLedgerPartitionRunwayLow

A partitioned table has under 31 days of future partitions. A healthy install sits near 90, because
the daily job creates three months ahead, so reaching 31 means it has not completed for about two
months.

Check which table and how fast it is draining:

```promql
min by (table) (agledger_partition_runway_days)
```

Do: find out why the job stopped, which is `AGLedgerPartitionMaintenanceFailing` or
`AGLedgerPartitionMaintenanceNotRunning`. Then refill, holding the sweep's advisory lock so a hand
refill and the daily job cannot both create the same month:

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('partition-management'));
SELECT * FROM ensure_future_partitions(3);
COMMIT;
```

This rule excludes anything already under 7 days, so it and the critical rule never page for the same
table.

Silence: up to a week, once the refill has run and the gauge is climbing again.

## AGLedgerPartitionRunwayExhausted

Under a week of runway on a partitioned table. There is no longer room to schedule the fix. When it
reaches zero, inserts fail with `no partition of relation found for row`, and on `audit_vault` that
stops every chain append and with it every state transition.

Do this first, then investigate. The advisory lock is the sweep's own, so taking it here is what
stops a refill colliding with the 02:00 job on the same month:

```sql
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('partition-management'));
SELECT * FROM ensure_future_partitions(3);
COMMIT;
SELECT table_name, runway_days FROM partition_runway();
```

If the call cannot take its locks, find what is holding them:

```sql
SELECT pid, state, wait_event_type, left(query, 80) FROM pg_stat_activity
 WHERE datname = current_database() ORDER BY xact_start LIMIT 10;
```

Every worker re-reads the runway every 10 minutes, so the alert clears within that of the refill.

Do: after the refill, work out why the daily job stopped. A refill without that just moves the
outage three months out.

Silence: never.

## AGLedgerPartitionDefaultRowsPresent

Rows are sitting in a table's DEFAULT partition, which should read zero. Only `system_audit_log` has
one today, so this fires for it alone. Nothing is blocked either way: this is a lag signal, not a
latch.

Check the dates on those rows:

```sql
SELECT min(created_at), max(created_at), count(*) FROM system_audit_log_default;
```

Do: if the dates fall within the next three months, the nightly job drains them into their own
partition on its next run, because `ensure_future_partitions()` detaches the default, creates the
months, moves what now has a home and re-attaches. Wait a day. If it is still firing,
`AGLedgerPartitionMaintenanceFailing` or `AGLedgerPartitionMaintenanceNotRunning` will say which half
is broken. If the dates are older than the earliest monthly partition or further ahead than three
months, the job would never have created that month and the rows are simply parked.

Silence: yes, for parked rows outside the job's window. A day at a time otherwise.

## AGLedgerFederationZeroRowNearHorizon

Terminal records that should have federated and have no outbound delivery row at all are waiting
for the zero-row recovery sweep, and the oldest has used more than half of the recovery horizon
(`AGLEDGER_FEDERATION_ZERO_ROW_HORIZON_MINUTES`). A record older than the horizon leaves the sweep's
window and never reaches its peers, with nothing else to re-drive it.

Check how old, and whether the sweep is filling its batch:

```promql
max by (kind) (agledger_federation_zero_row_oldest_candidate_age_seconds) / 60
max (agledger_federation_zero_row_horizon_seconds) / 60
```

and the worker log for `Federation zero-row recovery filled its batch`.

Do: a full batch every cycle means more records lose their outbound row than one cycle re-drives;
raise `AGLEDGER_FEDERATION_ZERO_ROW_BATCH_SIZE`. A zero-row candidate is a crash between a record's
commit and its outbound write, so a steady supply of them means a worker that keeps dying mid-publish:
read the worker's restarts and its log before raising anything.

Silence: no. A record past the horizon is lost to its peers.

## AGLedgerFederationDeadLettered

Outbound federation jobs exhausted their retries and dead-lettered. They will never reach the peer
without an operator redrive. The `kind` label says which message type.

Check the queue:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/dlq"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/peers"
```

Do: the recovery sweep re-enqueues entries automatically after a cooldown, every ten minutes, so a
transient peer outage drains on its own. Entries older than 24 hours are left for manual triage
because they usually reflect a peer config change: a rotated signing key, a moved endpoint, a revoked
peering. Fix the peer record, then redrive:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/dlq/recover"
```

Silence: through a known peer maintenance window.

## AGLedgerFederationDeliveriesGivenUp

Dead-lettered federation legs first failed more than a day ago, so the recovery sweep has stopped
re-enqueueing them. A leg here reaches its peer only through a manual recover, and pg-boss deletes a
dead-lettered job 14 days after it dead-lettered; after that the peer never gets it, and nothing
records that it did not.

Check how many, and which peers:

```promql
max by (sweep) (agledger_federation_dlq_jobs)
max(agledger_federation_dlq_oldest_first_failure_age_seconds) / 3600
```

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/dlq"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/peers"
```

Each listed job carries `peerHubId`, `kind` and `firstFailedAt`. A day of failure is almost always
the peer's configuration rather than an outage: a rotated signing key, a moved endpoint, a revoked
peering.

Do: fix the peer, then redrive. Preview first with `dryRun`, which reports what would move:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" -H 'Content-Type: application/json' \
  -d '{"dryRun":true}' "$AGLEDGER_URL/federation/v1/admin/dlq/recover"
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/federation/v1/admin/dlq/recover"
```

A redriven leg keeps its first-failure time, so one that fails again comes straight back here
rather than getting another day of automatic retries. The recover reaches only legs that first
failed within the last 30 days. One older than that stays counted here, `dryRun` reports nothing to
move, and it waits in the DLQ until pg-boss deletes it: record which peer and record it was for from
the listing, and reconcile with the peer by hand.

Silence: while a peer that is being decommissioned is removed. Its legs will never land.

## AGLedgerFederationSchemaDigestMismatch

A peer asserted a schema digest this Server does not hold. The two Servers registered the same
(publisher, type, version) from different bytes, so a message referencing it cannot be validated
against the same schema on both sides.

Check which type and which operation:

```promql
sum by (operation) (increase(agledger_federation_schema_digest_mismatch_total[24h]))
```

then compare the registered schema on both Servers:

```bash
curl -sS "$AGLEDGER_URL/v1/schemas/<type>"
```

`/v1/schemas` is unauthenticated on both ends, so you can read the peer's copy directly.

Do: re-import the manifest on one side so the digests agree. Editing a registered schema's
description is enough to change the digest, so a cosmetic edit on one Server is the usual cause.

Silence: yes, until the next maintenance window, if the affected type is not in use across the peer
link.

## AGLedgerWebhooksDeadLettered

Webhook deliveries were dead-lettered in the last hour for the `reason` the alert names. The
receiver never got them, and nothing retries a dead-lettered delivery: each stays in
`webhook_delivery_dlq` until an operator retries or discards it. Reasons:

- `retries_exhausted`: the endpoint failed every attempt of the retry ladder.
- `circuit_open`: the endpoint's breaker is open, so deliveries skip the attempt.
- `gone`: the receiver answered 410, which also deactivated the subscription.
- `redirect`, `client_error`: the receiver answered a 3xx or a 4xx, which is not retried.
- `ssrf_blocked`: the URL resolves to an address the egress guard refuses (`SSRF_ALLOW_CIDRS`).
- `secret_missing`, `secret_undecryptable`, `signing_key_missing`: this Server could not sign
  the delivery.

`paused` and `subscription_inactive` dead-letter too, and are left out of this alert. A pause is the
operator's choice. A subscription is inactive after a delete, a provisioning prune, or the engine
deactivating it, which follows a `gone` or `circuit_open` dead letter this alert has already fired
on.

Check what is parked and which endpoints are failing:

```promql
max(agledger_webhook_dlq_entries)
max(agledger_webhook_dlq_oldest_age_seconds) / 3600
```

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhook-dlq?limit=50"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhooks/health"
```

Do: fix the endpoint or the signing material first, then retry one entry, or a batch with
`retry-all`, which takes the newest entries first:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhook-dlq/<dlqId>/retry"
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhook-dlq/retry-all"
```

An entry whose subscription is inactive is refused on retry (422, `allowedActions: ["discard"]`),
and `retry-all` leaves it in place and counts it in `skippedInactive`. The listing marks it
`subscriptionActive: false`. It counts in `agledger_webhook_dlq_entries`, and keeps
`GET /v1/admin/system-health` degraded, until it is discarded or its subscription is active again
(a provisioning reload reactivates one its directory still declares, after which it retries):

```bash
curl -sS -X DELETE -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhook-dlq/<dlqId>"
```

A discard does not lose the event: `GET /v1/events` and the record still carry it.

Silence: while a known receiver outage is being fixed.

## AGLedgerWebhookSubscriptionsNotDelivering

Webhook subscriptions have stopped taking deliveries. The `state` label says how:

- `breaker_open`: the endpoint failed enough consecutive deliveries to open its circuit breaker,
  and it keeps reopening: after each cool-down the next event is sent as a probe, and it failed.
- `disabled`: the engine deactivated the subscription after its breaker stayed open through
  sustained failures (a receiver answering 410 deactivates it too, and counts here when its breaker
  was open).

Either way, new events for the subscription are skipped at dispatch: they are dropped, not
dead-lettered, so `AGLedgerWebhooksDeadLettered` does not count them and a DLQ retry cannot bring
them back.

Check which subscriptions, and what they last did:

```promql
max by (state) (agledger_webhook_subscriptions_not_delivering)
```

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/webhooks/health"
```

Each row of the health listing carries `circuitState`, `consecutiveFailures`, `isActive` and when
it last delivered and last failed. The delivery history, with the receiver's responses, is at
`GET /v1/webhooks/<webhookId>/deliveries`, which answers only the subscription's owner, so read it
with the owning org's admin key.

Do: fix the receiver first. Then close the breaker, which resets its failure count and lets
deliveries resume:

```bash
curl -sS -X PATCH -H "Authorization: Bearer $AGLEDGER_KEY" -H 'Content-Type: application/json' \
  -d '{"state":"closed"}' "$AGLEDGER_URL/v1/admin/webhooks/<webhookId>/circuit-breaker"
```

A `disabled` subscription stays inactive after that: its owner re-creates it, or a provisioning
reload reactivates one its directory declares. Closing its breaker is also how a subscription that
was deleted on purpose while failing is dismissed from this alert and from the health listing.

The events the subscription missed are recovered by the receiver replaying
`GET /v1/events?since=<its lastSuccessfulAt>`, or its `createdAt` if it never delivered.
`circuitOpenedAt` moves each time a failed probe
reopens the breaker, so it can be later than the first event dropped. Retry what was dead-lettered
while it was failing from `GET /v1/admin/webhook-dlq`.

Silence: while a known receiver outage is being fixed.

## AGLedgerTrustedIssuerJwksFailing

Enabled trusted issuers are failing to fetch the keys at their `jwks_uri`, so OIDC tokens they
would validate are refused with the outcome as their reason: admin bearers, the ephemeral
certificate exchange, and delegated on-behalf-of calls. The `outcome` label says which failure:

- `jwks_fetch_failed`: the host is unreachable, timed out, answered non-200, or served something
  that is not a JWKS.
- `jwks_fetch_blocked`: the SSRF egress guard refused the address this Server resolved it to.

A replica whose key cache for the row is still warm keeps accepting its tokens until the cache
expires, so callers can see refusals from one replica and not another for a few minutes.

Check which rows, and what the fetch said:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/trusted-issuers?enabled=true"
```

The listing's `nextSteps` names the failing rows; each row carries `jwksLastFetchOutcome`,
`jwksLastFetchError` and `jwksLastSuccessAt`, the last of which says how long it has been unable to
refresh its keys.

Do: for `jwks_fetch_blocked`, add the IdP's address range to `SSRF_ALLOW_CIDRS` on the Server and
restart it; the setting is read at startup. No value admits loopback or cloud metadata, so a
`jwksUri` on one of those has to move to an address the Server reaches from outside itself. For `jwks_fetch_failed`, check egress from the Server to
the IdP, then the URL itself. Correct a wrong URL with `PATCH /v1/admin/trusted-issuers/{id}`, which
clears the recorded outcome, and disable an issuer nobody uses with the same PATCH and
`{"enabled": false}`. A row with `managedBy: "provisioning"` refuses the PATCH with 409; change it in
its provisioning file and reload instead.

The gauge counts a failure recorded in the last 15 minutes. A failing row is refetched on every
token presented against it and re-recorded while they keep arriving, so the alert holds through a
live outage and clears once the IdP answers or the tokens stop.

Silence: while a known IdP outage is being fixed.

## AGLedgerDisputesStuck

Disputes are sitting at `EVIDENCE_WINDOW` when the engine should have moved them to
`PENDING_RESOLUTION`, where the record's principal is asked to resolve them. The `reason` label says
which:

- `window_overdue`: the evidence window closed more than 15 minutes ago and the
  `evidence-window-expiry` sweep has not moved the dispute. The sweep is failing, is not running,
  or is behind a burst of disputes whose windows closed together.
- `no_window_close`: the dispute has no close instant, so the sweep has nothing to act on and will
  never move it. Every path that opens a dispute sets one, so this is a row written some other way.

Check:

```promql
max by (reason) (agledger_disputes_stuck)
sum(increase(agledger_maintenance_sweep_failures_total{task="evidence-window-expiry"}[3h]))
```

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/disputes?status=EVIDENCE_WINDOW"
```

The worker's `dispute-stale-recovery` sweep logs them every five minutes, oldest first up to a cap,
with each one's `disputeId` and `recordId`.

Do: for `window_overdue`, read the worker log for the `evidence-window-expiry` sweep's error, or
confirm the worker is running at all (`AGLedgerWorkerTargetAbsent`); once the sweep runs, it drains
the backlog oldest first over successive cycles. For `no_window_close`, the dispute can still be
closed: the record's principal or an org-admin key resolves it at
`POST /v1/disputes/{id}/resolve`, which is accepted from `EVIDENCE_WINDOW`, or its initiator or an
org-admin key withdraws it at `POST /v1/records/{recordId}/dispute/withdraw`.

Silence: never for `no_window_close`, which does not clear on its own.

## AGLedgerHighErrorRate

More than 5% of requests returned 5xx for ten minutes. `keep_firing_for: 5m` holds the alert through
a single good evaluation, so a dip does not resolve and refire it as a second incident.

Check which route and which status:

```promql
topk(5, sum by (route, status_code) (rate(agledger_http_request_duration_seconds_count{status_code=~"5.."}[5m])))
```

then:

```bash
curl -sS "$AGLEDGER_URL/health/ready"
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/system-health"
```

Do: 5xx concentrated on one route is application; spread across all of them is almost always the
database. Check `AGLedgerDbPoolSaturated` and `AGLedgerDbConnectionsDropping` before reading code.
The API log carries the error and the request id for each.

Silence: no.

## AGLedgerHighLatency

P95 request latency has been above 2 seconds for ten minutes. Same `keep_firing_for: 5m` hold as the
error-rate rule, for the same reason.

Check where it is:

```promql
topk(5, histogram_quantile(0.95, sum by (route, le) (rate(agledger_http_request_duration_seconds_bucket[5m]))))
```

and whether the process is saturated rather than the query:

```promql
agledger_nodejs_eventloop_lag_p99_seconds
agledger_db_pool_waiting_connections
```

Do: event loop lag moving with the latency means the process is CPU-bound, and
`AGLedgerEventLoopLagging` should be firing too. Pool waiters moving with it means the database is
the bottleneck. Neither moving means a slow query on one route; the API log records the duration per
request.

Silence: during a known bulk import or backfill.

## AGLedgerDbPoolSaturated

Requests have been queued waiting for a database connection for five minutes. This is the shape a
pool deadlock takes from the outside.

Check the pool and the database side together:

```promql
agledger_db_pool_waiting_connections
agledger_db_pool_total_connections
agledger_db_pool_idle_connections
```

```sql
SELECT state, count(*), max(now() - state_change) AS oldest
  FROM pg_stat_activity WHERE datname = current_database() GROUP BY state;
```

Do: total at `DATABASE_POOL_MAX` with zero idle and waiters climbing is either an undersized pool or
a handler holding a client across an await. Long `idle in transaction` backends point at the second.
`DATABASE_IDLE_IN_TX_TIMEOUT_MS` (default 30000) rolls those back; a zero there removes the safety
net. Raising `DATABASE_POOL_MAX` buys time and does not fix a leak.

Silence: no.

## AGLedgerDbConnectionsDropping

Backends have been dying under checked-out clients for ten minutes. Each one rejects the in-flight
query and evicts the client, so an open transaction is lost every time: for a pg-boss job that is a
retry, for a request a 500.

Check the rate and the shape:

```promql
sum(rate(agledger_db_client_connection_errors_total[10m]))
```

Counts roughly double, because one backend death raises both the FATAL message and the socket close.
A burst of about twice the pool size that stops is a failover, and the ten-minute hold rides over it.
A steady trickle is not.

Do: check the database for restarts, failovers and OOM kills, and the network path if the database is
external. `SELECT pg_postmaster_start_time();` says whether Postgres itself restarted. A flapping
path or something terminating backends on a timer is the case this rule is written for.

Silence: through a planned failover.

## AGLedgerQueueBacklogGrowing

A pg-boss queue has held more than 1000 jobs ready to run and not taken for fifteen minutes. Either
the worker is down or it cannot keep up. Jobs waiting out a retry backoff are `deferred` and do not
count: no added worker runs them sooner.

Check which queue and whether anything is running:

```promql
max by (queue, state) (agledger_pgboss_queue_size)
sum by (queue) (rate(agledger_worker_jobs_processed_total[5m]))
```

Do: zero processing rate with a growing backlog means the worker is gone, and
`AGLedgerWorkerTargetAbsent` should be firing. A nonzero rate that cannot keep up is a throughput
problem: scale the worker, or find the slow handler in
`agledger_maintenance_sweep_duration_seconds`. A backlog on `webhook-delivery` specifically is often
one slow endpoint, which `GET /v1/admin/webhooks/health` will name.

Silence: during a known burst, such as a bulk import.

## AGLedgerWorkerJobsFailing

More than 10% of worker jobs have failed for ten minutes. Retries are counted as failures each time,
so a persistent failure inflates this faster than the job count suggests.

Check which queue:

```promql
sum by (queue, status) (rate(agledger_worker_jobs_processed_total[10m]))
```

then the worker log for the handler error.

Do: a single failing queue usually points at an external dependency: a webhook endpoint that is down,
a peer that will not accept a signed message, an S3 anchor bucket that has lost its credentials.
Jobs that exhaust their retries surface separately as `AGLedgerGateJobRetriesExhausted` or
`AGLedgerFederationDeadLettered`, so check those for what has already been lost.

Silence: during a known outage of whatever the failing queue talks to.

## AGLedgerMaintenanceSweepFailing

One periodic maintenance sweep has failed at least twice in three hours. `AGLedgerWorkerJobsFailing`
above does not cover this: the maintenance queue multiplexes about twenty sweeps into one queue
label, so a single sweep failing every cycle stays well under that rule's 10% ratio while everything
else on the worker succeeds.

Check which sweep, and whether any cycle is getting through:

```promql
sum by (task) (increase(agledger_maintenance_sweep_failures_total[3h]))
sum by (task) (increase(agledger_maintenance_sweep_rows_total[3h]))
```

The rows series exists only for tasks that report a row count, so its absence means one of two
things and the task name says which. `marketplace-license-check` reports none by design: it refreshes
an entitlement and acts on no rows. Every other task reports one, and for those an absent series
means no cycle has completed since the worker started.

Then the worker log for the throw itself:

```bash
docker compose -f deploy/compose/docker-compose.yml logs --tail=500 agledger-worker | grep -i maintenance
```

Do: what the failure costs depends on the task, and the name says which.

- `record-expiry`, `evidence-window-expiry`, `dispute-stale-recovery`: records sit past their
  deadline in a non-terminal state. Nothing is lost, and the next successful cycle catches up.
- `idempotency-cleanup`, `rate-limit-cleanup`, `oidc-jti-cleanup`,
  `webhook-secret-grace-cleanup`: a table grows without bound. Check its row count before deciding
  how long you can leave it.
- `gate-recovery`, `cascade-cancel-recovery`, `auto-rollup-consistency`,
  `federation-dlq-recovery`, `federation-pending-recovery`: these ARE the recovery path for work
  the queue dropped, so a failing one means the engine's own safety net is off.
- `vault-checkpoints`, `vault-integrity-check`, `vault-anchor-verify`,
  `org-admin-reads-checkpoints`: the chain keeps accepting writes and stops being checkpointed or
  checked. `POST /v1/admin/vault/scan` covers the integrity check on demand; the two checkpoint
  sweeps have no manual door, and a gap in them is a stretch of chain with no signed
  checkpoint over it.
- `webhook-circuit-breaker`: a subscription that tripped its breaker is never half-opened again, so
  an endpoint that has recovered stays cut off, and a chronically failing one is never disabled.
  `GET /v1/admin/webhooks/health` shows the current state, and the circuit override on a
  subscription is the manual way back.
- `marketplace-license-check`: nothing is gated on the tier, so a failing cycle changes a label and
  a WARN banner, not behaviour. This is the one entry here that can wait.
- `partition-management`: this one has its own CRITICAL rule,
  `AGLedgerPartitionMaintenanceFailing`, and its runbook above is the one to follow.

Most failures here are the database: a statement timeout, a missing GRANT after a role change, or a
pool with nothing free. The throw in the worker log names which.

Silence: for a cleanup sweep whose table you have checked, while the database problem is fixed.
Never for a recovery sweep.

## AGLedgerVaultCheckpointsFallingBehind

Each checkpoint run reads the records table in id order, oldest first, and checkpoints every chain
with entries past its last checkpoint, anchoring as it goes, for up to 45 seconds plus the chain,
page and anchor batch in progress when the time runs out. A run that runs out
of time stops there, and the next run goes on from that point. This alert means every run in the
last thirteen hours stopped before the end of the table. At a `VAULT_ANCHOR_INTERVAL_MINUTES` above
780 a thirteen-hour window can hold no run, so the alert cannot fire; watch the `behind` series
directly at that cadence.

What it costs: an entry has no signed checkpoint until a run reaches its chain, and with
`VAULT_ANCHOR_ENABLED` no S3 anchor either. A deleted or rewritten entry is caught by the hash walk
either way, but truncation from the end of a chain is caught only by a checkpoint.

Check:

```promql
sum(increase(agledger_maintenance_sweep_behind_total{task="vault-checkpoints"}[13h]))
sum(increase(agledger_maintenance_sweep_rows_total{task="vault-checkpoints"}[13h]))
histogram_quantile(0.95, sum by (le) (rate(agledger_maintenance_sweep_duration_seconds_bucket{task="vault-checkpoints"}[13h])))
```

Do: shorten `VAULT_ANCHOR_INTERVAL_MINUTES` so runs come more often; each run's budget is fixed. A
steady row count means the runs are working and the write rate is above what they cover at this
cadence. A falling one means the database or the signer has slowed down (check
`AGLedgerVaultSignerUnreachable` and the database pool alerts). The first runs after an upgrade from
a release that checkpointed a fixed 100 chains per run work through the backlog that release left,
and can hold this alert for as long as that takes.

Silence: while a known backlog drains and the row count is climbing. Never otherwise.

## AGLedgerExpiryRollupFailing

The expiry sweep rolls each FAILED child that passed its deadline (its principal can no longer
request a revision, so the child counts as failed) up onto its ACTIVE parent, which fails, or
expires when it is past its own deadline. It catches each
parent's failure so that one parent cannot hold back the rest, so the sweep itself completes and
`AGLedgerMaintenanceSweepFailing` does not fire. This one does: at least two such attempts threw in
three hours.

Check which records, and why:

```bash
docker compose -f deploy/compose/docker-compose.yml logs --tail=1000 agledger-worker \
  | grep 'rolling a FAILED child past its deadline up onto its parent threw'
```

Each line carries the parent's `recordId` and the error.

Do: a database error (a lock timeout, a pool exhausted) clears on its own and the next cycle rolls
up the parent. An error that repeats for the same record is a defect: capture the log line and the
record, and file it. The parent stays ACTIVE in the meantime and its principal can still close it
by its own completion or cancellation.

Silence: while a known database incident is in progress.

## AGLedgerMaintenanceSweepFallingBehind

A maintenance sweep that bounds its own work has spent at least six of the last hour's cycles
stopping with rows still waiting. Two sweeps report it, and the alert's `task` label says which.
The consumed-jti register first; `idempotency-cleanup` has its own section below.

`oidc-jti-cleanup` drains the
consumed-jti register (`oidc_consumed_jtis`) in batches of 1000 for up to 30 seconds a cycle, every
5 minutes, and a cycle that hits the 30 seconds with expired rows left reports itself behind.

Nothing is failing and nothing is lost. Every row the sweep deletes belongs to a token whose `exp`
has passed, so a row left behind refuses nobody and admits nobody; what grows is the table and its
index. This is a capacity reading, not an error.

Which sweep, and how much it is getting through:

```promql
sum by (task) (increase(agledger_maintenance_sweep_behind_total[1h]))
sum by (task) (increase(agledger_maintenance_sweep_rows_total[1h]))
histogram_quantile(0.95, sum by (task, le) (rate(agledger_maintenance_sweep_duration_seconds_bucket[1h])))
```

Read the three together. A high row count with cycles at the full 30 seconds is a sweep losing to an
admission rate. A low row count at the full 30 seconds is a database that has slowed down, and the
sweep is the symptom rather than the subject.

What feeds the register is admin and platform bearers accepted on a row with single use on, one row
each. Two things narrow that. Only the bearer door writes here, so a row serving agents
(`appliesTo: "agent"`) contributes nothing however its flag is set, and the cert exchange dedups in
its own table (`ephemeral_certs.oidc_jti`) rather than this one. And only a token that resolves an
id is registered: on a row whose tokens carry no `jti` and no `claimMapping` `jti`, the flag is
inert and `agledger_oidc_admin_jti_unenforceable_total` is counting instead.

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/admin/trusted-issuers" \
  | jq -c '.data[] | select(.jtiSingleUse) | {id, issuerUrl, appliesTo, managedBy, label}'
```

Do: decide whether the rate is meant. An issuer whose client mints a token per request is the shape
`jtiSingleUse` exists for, and a sustained rate past what the database can delete is a sizing
question, not a misconfiguration. Options, in the order worth trying:

- Check the table's actual size before anything else. A register holding a few million dead rows is
  a table to leave alone; one growing without a ceiling is not.
  `SELECT count(*), pg_size_pretty(pg_total_relation_size('oidc_consumed_jtis')) FROM oidc_consumed_jtis;`
- Give the database what the sweep is waiting on. The batch is a `DELETE ... WHERE ctid IN (SELECT
  ctid ... WHERE expires_at < $now LIMIT 1000)` over `idx_oidc_consumed_jtis_expires_at`, so it is
  bound by write throughput and by autovacuum keeping up with the churn. Check for bloat
  (`pg_stat_user_tables.n_dead_tup`) and for an autovacuum that is not running on this table.
- Turn single use off on an issuer that does not need it (`PATCH /v1/admin/trusted-issuers/{id}`
  with `{"jtiSingleUse": false}`, or an edit to the provisioning YAML plus
  `POST /v1/admin/provisioning/reload` for a row whose `managedBy` is `provisioning`, which PATCH
  answers with 409). The register stops taking rows from that issuer immediately, and bearers it
  validates become reusable until their `exp`, which is a security decision, not a cleanup one.

Silence: while the table's size is known and acceptable, and for as long as the rate that feeds it
is expected. Not open-ended: the alert clears itself within the hour once the sweep catches up, so a
warning that keeps coming back is a table that keeps growing.

### task="idempotency-cleanup"

This sweep drains `idempotency_keys` on the same batch, budget and cadence as the jti register, in
two arms: keys past their seven-day TTL that finished, and claims still in flight an hour after they
were taken, which belong to requests that crashed before releasing them. One row lands per mutation
sent with an `Idempotency-Key` header, so what feeds it is the write rate of callers that use the
header.

Nothing is lost, and what a lagging cycle leaves differs by arm. An expired key the sweep has not
reached still replays its cached response to a caller that resends it, which is the behaviour the
caller already had inside the TTL, carried a little longer. A crashed claim the sweep has not
reached keeps answering 409 to a retry with that key, so a backlog in this arm is callers waiting
longer than the hour to reuse a key. `SELECT count(*) FROM idempotency_keys WHERE in_flight AND
created_at < now() - interval '1 hour';` says which arm the backlog is in.

Do: check the table's size first
(`SELECT count(*), pg_size_pretty(pg_total_relation_size('idempotency_keys')) FROM idempotency_keys;`),
then the same bloat and autovacuum checks as above. Each arm deletes through its own index
(`idx_idempotency_keys_expires`, `idx_idempotency_keys_in_flight`), so a cycle that runs to its
budget with a low row count is the database, not the query.

Silence: on the same terms as the jti register.

## AGLedgerApiKeyExpiringTomorrow

Active API keys expire within 24 hours. An expired key stops authenticating with no warning to its
holder, and the failure surfaces as the agent it belonged to going quiet.

List them:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/admin/api-keys?isActive=true&expiresBefore=<tomorrow-iso8601>"
```

That filter has no lower bound, so it also returns keys that already expired, and `isActive` is the
revocation flag alone, so an expiring key still reads `true` there. Each row carries the `keyId`,
`ownerId`, `ownerType`, `role`, `scopes` and `allowedIps` the replacement needs.

Do: no admin route rotates a key the caller does not hold, so mint the replacement for the same owner
and revoke the old one. The plaintext key is returned once by the create, so hand it to the holder
before you revoke:

```bash
curl -sS -X POST -H "Authorization: Bearer $AGLEDGER_KEY" -H 'Content-Type: application/json' \
  -d '{"role":"agent","ownerId":"<ownerId>","ownerType":"agent","scopes":["<as listed>"]}' \
  "$AGLEDGER_URL/v1/admin/api-keys"

curl -sS -X PATCH -H "Authorization: Bearer $AGLEDGER_KEY" -H 'Content-Type: application/json' \
  -d '{"isActive":false,"reason":"replaced ahead of expiry"}' \
  "$AGLEDGER_URL/v1/admin/api-keys/<keyId>"
```

Both keys authenticate until the revoke lands, which is the overlap window on this path. Omitting
`scopes` gives the new key the role's default profile rather than whatever the expiring one carried.
For a sweep, `POST /v1/admin/api-keys/bulk-revoke` does the revoke half in one call.

`POST /v1/auth/keys/rotate` does not clear this alert. It replaces the CALLER's own secret and keeps
its `expiresAt`, so the replacement lapses no later than the rotated key would have; a rotation
that renewed would let a stolen key keep itself alive indefinitely. Renewal is the mint above.

If the key running out is the platform key you are working the alert with, the mint above is still
the route: a platform key mints platform keys, so present it to `POST /v1/admin/api-keys` with
`role: "platform"`, `ownerType: "platform"` and `ownerId: "00000000-0000-0000-0000-000000000000"`
before it lapses, confirm the new key authenticates, then revoke the old one.

The rule reads the 24-hour window rather than the 7-day one on purpose: an install running
`API_KEY_MAX_LIFETIME_SECONDS` keeps keys inside a 7-day window as its steady state, so a 7-day rule
would never clear on exactly the installs that adopted the control.

Expect this rule to fire on an install that has been running for 90 days without one:
`API_KEY_DEFAULT_LIFETIME_SECONDS` gives every admin and agent key a 90-day life unless the mint
named its own `expiresAt`, so the first cohort comes due together. Platform keys are exempt by
default (`AGLEDGER_PLATFORM_KEY_DEFAULT_LIFETIME_SECONDS`, `0`), and the engine logs a WARN at boot
when the last active platform key is inside 14 days of expiry: that one has no recovery once it
lapses, because minting a platform key requires a platform credential. Mint its replacement with it
while it still works, as above, or register a trusted issuer mapped to the platform role first.

Silence: yes, if the keys are known to be retiring with their agents.

## Dormant API keys (no alert)

`agledger_api_keys_dormant{window="30d"}` and `{window="90d"}` count active keys nothing has
presented inside that window, plus keys created before it that have never authenticated at all.
There is no shipped alert on either: a credential going quiet is a standing inventory question, not
an incident, and an install with seasonal agents would page on its own steady state.

No panel ships for it either; add one where your key inventory lives, and work the number on a
cadence. The listing behind it:

```bash
# used once, and not since
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/admin/api-keys?isActive=true&lastUsedBefore=<90-days-ago-iso8601>"

# minted long enough ago to have been used, and never was
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" \
  "$AGLEDGER_URL/v1/admin/api-keys?isActive=true&neverUsed=true&createdBefore=<90-days-ago-iso8601>"
```

`last_used_at` is written on a key's next authenticated request, once per key per 5 minutes per
replica, so it is a mutable predicate: a key presented during the walk drops out of a later page,
and the gauge moves with it. Read a page as a snapshot. Check
`agledger_api_key_last_used_update_failures_total` before acting on a jump: while that write is
failing, keys in daily use start reading as dormant.

Do: confirm the holder is gone before revoking, since a key used quarterly is dormant every quarter
and still live. Then revoke, one key at a time or as a sweep:

```bash
curl -sX POST -H "Authorization: Bearer $AGLEDGER_KEY" -H 'Content-Type: application/json' \
  -d '{"lastUsedBefore":"<90-days-ago-iso8601>","reason":"dormant 90 days"}' \
  "$AGLEDGER_URL/v1/admin/api-keys/bulk-revoke"
```

`neverUsed` is refused on the sweep unless `createdBefore` is beside it, because on its own it also
matches the replacement key minted minutes ago. The lockout guard still applies: an org-admin sweep
that would leave the org with no working admin door is refused with 403 before anything is revoked.

## Open disputes (no alert)

`agledger_disputes_open{status}` counts disputes at `EVIDENCE_WINDOW` and `PENDING_RESOLUTION`, and
`agledger_disputes_open_oldest_age_seconds{status}` says how long ago the oldest of each was opened.
There is no shipped alert on either. A dispute at `PENDING_RESOLUTION` waits for the record's
principal to render an outcome at `POST /v1/disputes/{id}/resolve`, and the engine does not decide
for them however long it takes. The engine-side fault, a dispute the sweeps should have moved and
did not, is `AGLedgerDisputesStuck`.

Work the queue on a cadence that suits the install:

```bash
curl -sS -H "Authorization: Bearer $AGLEDGER_KEY" "$AGLEDGER_URL/v1/disputes?status=PENDING_RESOLUTION"
```

The worker also logs, at info and up to a cap per run, disputes that have sat at
`PENDING_RESOLUTION` for over a week.

## Records without a deadline (no alert)

`agledger_records_without_deadline{status}` counts records in a state a deadline would time out that
hold no deadline, and `agledger_records_without_deadline_oldest_age_seconds{status}` says how long
ago the oldest of each was created. `status` is the internal state (`DRAFT`, `REGISTERED`, `ACTIVE`,
`PENDING_VERDICT` and the rest of the `TIME_OUT` action's states in the authority declaration),
not the display status the API returns. The API reads it every 5 minutes rather than on every
scrape, because it reads the records table.

The expiry sweep reads the deadline, so it never times these out. A delegation parent can still be
failed by its children, and an automatically gated completion is still graded, but otherwise each
stays open until a party acts on it. A deadline is optional, and an install whose
agents register open-ended work carries a steady count here, which is why there is no shipped
alert. A count that only grows, or an oldest age of months, is the reading worth a look: work that
was abandoned without being cancelled.

The deadline cannot be added afterwards: it is frozen, with the criteria, once a record is
registered or proposed. What the parties can do is finish the work, or cancel the record at
`POST /v1/records/{id}/cancel`, which is refused once a completion is accepted: a record at
`COMPLETION_ACCEPTED` or `PENDING_VERDICT` ends by its gate or its principal's verdict. The record's
`allowedActions` say what is open to it. For new work, set `deadline` when the record is created.

## AGLedgerApiTargetAbsent

Nothing has published an API-only series for five minutes. Neither packaged install keeps a stopped
process in the target list: Compose discovers both services by DNS and a stopped one stops resolving,
while on Kubernetes the ServiceMonitor becomes operator-generated `kubernetes_sd_configs` over
endpoints and a stopped pod leaves the endpoint set. Either way the API disappears from the target
list rather than reporting `up == 0`, so `AGLedgerScrapeFailing` stays silent and this is the only
rule that sees it.

Check the process, then the scrape:

```bash
curl -sS "$AGLEDGER_URL/health"
curl -sS -H "Authorization: Bearer $METRICS_AUTH_TOKEN" "$AGLEDGER_URL/metrics" | head -5
```

and Prometheus' own target list at `/targets`.

Do: if `/health` answers, this is a scrape problem rather than an outage. The usual causes are a
changed service name in the scrape config, a `METRICS_AUTH_TOKEN` that no longer matches, and a
NetworkPolicy that no longer admits Prometheus. If `/health` does not answer, read the API log for a
boot failure: a missing `VAULT_SIGNING_KEY`, a missing `AGLEDGER_EXTERNAL_URL` and a database that
refuses SSL all fail fast in production by design.

Silence: through a planned API outage, and only with the worker still scraped.

## AGLedgerWorkerTargetAbsent

Nothing has published a worker-only series for five minutes. With no worker, gate evaluation, webhook
delivery, record expiry, partition maintenance and every recovery sweep have stopped, and the API
keeps returning 200 the whole time.

Check the worker's own health port, which is separate from the API's and is not published to the
host by either packaged install (`WORKER_HEALTH_PORT`, default 3001):

```bash
docker compose -f deploy/compose/docker-compose.yml exec agledger-worker \
  /nodejs/bin/node -e "fetch('http://localhost:3001/health/ready').then(r=>r.text()).then(console.log)"

kubectl port-forward -n <ns> "$(kubectl get deploy -n <ns> -l app.kubernetes.io/instance=<release>,app.kubernetes.io/component=worker -o name | head -1)" 3001:3001 &
curl -sS http://localhost:3001/health/ready
```

Do: the worker refuses to serve `/metrics` with a 503 when `METRICS_AUTH_REQUIRED` is on and no
`METRICS_AUTH_TOKEN` is set, which looks exactly like this alert while the process is perfectly
healthy. Check that first. Otherwise read the worker log: it exits 1 on a boot failure rather than
staying up, so the last lines say why. Queue depth confirms the impact:

```promql
max by (queue) (agledger_pgboss_queue_size{state="ready"})
```

Silence: through a planned worker outage. Expect `AGLedgerQueueBacklogGrowing` to follow.

## AGLedgerScrapeFailing

A target Prometheus still holds has failed its scrape for five minutes. This is the case the
`absent()` rules cannot see: the series is there and its value is 0. Every rule that reads a metric
from this target is now evaluating stale or absent data.

Check Prometheus' `/targets` page for the error string, then reproduce it:

```bash
curl -sS -i -H "Authorization: Bearer $METRICS_AUTH_TOKEN" http://<target>/metrics | head -20
```

Do: a 401 means the scrape token does not match the process. A 503 from the worker means
`METRICS_AUTH_REQUIRED` is on with no token configured, which is a deliberate refusal rather than a
fault. A scrape that trips `sample_limit` is reported as a failed scrape with the target still
present and no HTTP error at all, so check that limit against the payload size if the endpoint looks
healthy by hand.

Silence: during a planned restart of that target.

## AGLedgerProcessRestarting

A process has restarted more than twice in an hour. Three starts in an hour is past anything a
rollout explains on a stable install.

Check which process and how often:

```promql
changes(agledger_process_start_time_seconds[1h])
```

then the container exit reason:

```bash
docker compose -f deploy/compose/docker-compose.yml ps
kubectl get pods -l app.kubernetes.io/instance=<release>
kubectl describe pod <pod>
```

Do: a restart loop discards whatever was in flight each time. An open transaction rolls back, a
pg-boss job goes back for retry, and in-memory rate-limit state starts over. It also resets every
counter in this file, which makes the `increase()` windows elsewhere read low, so do not trust the
other alerts while this one is firing. An OOM kill shows as exit code 137; a boot failure shows as
exit 1 with the reason in the process log.

Silence: during a rollout. Not otherwise.

## AGLedgerEventLoopLagging

Event loop p99 lag has been above half a second for ten minutes. Node is single-threaded, so this is
saturation ahead of symptom: work is queued behind the loop before any of it shows up as request
latency, and `AGLedgerHighLatency` needs completed requests to move before it can say anything.

Check the process and its CPU budget together:

```promql
agledger_nodejs_eventloop_lag_p99_seconds
rate(agledger_process_cpu_user_seconds_total[5m])
agledger_process_resident_memory_bytes
```

Do: CPU rate pinned at the container limit is starvation, and the fix is more CPU or more replicas. A
lag that spikes rather than sits is usually one synchronous piece of work: a large JSON body, a gate
rule doing heavy regex, or a schema `pattern` that backtracks.
`agledger_gate_regex_timeout_total` and `agledger_schema_validation_timeout_total` count the two the
engine terminates itself.

Silence: during a known bulk import or backfill.
