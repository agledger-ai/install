# Changelog

This changelog tracks changes to the AGLedger installer (this repository) and, from v1.7.0 on, the server changes each release ships against.

Releases here are tagged to match the AGLedger server version they ship against.

## v2.0.0 - 2026-10-05

Scripts, Compose files, and Helm chart synced to AGLedger server v2.0.0.

2.0 does not upgrade a 1.x install. `upgrade.sh` refuses an install whose recorded or running version is 1.x before it writes `.env`, takes a backup or stops anything, and `restore.sh --keep-version` refuses a 1.x archive before anything is stopped or dropped. On Helm with the bundled PostgreSQL, the 2.0 chart refuses to render over a release a 1.x chart installed, so `helm upgrade` fails before any pod is replaced; the check reads the release through `lookup`, which answers nothing under `helm template` or Argo CD. Install 2.0 as a new release against a new, empty database, and keep the 1.x database for the 1.x install that wrote it. After a refused upgrade, put the checkout back on the 1.x tree: a `docker compose` command run from the 2.0 tree starts 2.0 against the 1.x database.

The API and worker no longer connect as the database owner. On the bundled PostgreSQL they serve as `agledger_app`, and the migration runs as the owner and gives `agledger_app` its login from `AGLEDGER_APP_ROLE_PASSWORD` on every run. `install.sh` generates that password, and the chart derives it from the owner password. With an external database, put the owner in `DATABASE_URL_MIGRATE` and `agledger_app` in `DATABASE_URL`, and set `AGLEDGER_APP_ROLE_PASSWORD` where the migration runs. Preflight warns when the runtime role owns the audit chain, since an owner passes every privilege check and the chain's append-only revokes then bind nothing.

The installers print the vault signing key's pin (`sha256:` of its public key) and the verifier floor: anyone verifying a 2.0 chain offline needs `@agledger/verify` 2.0.0 or later, and passes the pin as `--trust-anchor`. `install.sh` and `upgrade.sh` stop on an `API_KEY_SECRET` or `WEBHOOK_ENCRYPTION_KEY` the Server would refuse in production before pulling images.

On Kubernetes, `instanceId` (`AGLEDGER_INSTANCE_ID`) is generated on install and kept across upgrades. `serviceAccount.automountToken` defaults to false, so no pod the chart creates mounts a Kubernetes API token. Each `networkPolicy.ingressFrom` entry needs a `namespaceSelector` beside its pod label, and `networkPolicy.extraEgress` opens api and worker egress to anything beyond the shipped rules, such as an anchor store that is not public S3. A `postRestore` CronJob, which never fires on its own, runs the post-restore steps in the api image on a cluster. On the bundled PostgreSQL the migrate Job's name carries a hash of its rendered spec, so Argo CD and Flux migrate on a new image. `helm-install.sh` waits for the worker as well as the api, refuses a bundled install on a cluster with no default StorageClass, and keeps the release's image tag on a re-run without `--version`.

The bundled PostgreSQL image is pinned by digest, the same reference in Compose, the chart and the backup fallback. `backup.sh` writes its archive under umask 077.

The alert rules grow from 43 to 56. New alerts cover chain writes refused after a detected rewind (`AGLedgerChainWritesRefused`), entries signed outside their key's window (`AGLedgerVaultKeyWindowViolation`), anchors not landing and checkpoints falling behind, dead-lettered webhooks and subscriptions that deliver nothing, federation deliveries given up, stuck disputes, failing trusted-issuer JWKS fetches, provisioning errors and a downed cache-invalidation listener. The rules assume the direct `/metrics` scrape.

Adds two example recipes: `agent-drift`, an ops loop over `GET /v1/agents/drift`, and an OIDC workload-identity variant of `insurance`.

Server changes in v2.0.0:

2.0 does not upgrade a 1.x database in place. The schema ships as a single baseline, `001_consolidated.sql`, and the migration runner refuses a database a 1.x release migrated before it applies anything, exiting 65 and saying to install against a new, empty database: point `DATABASE_URL` (and `DATABASE_URL_MIGRATE` and `DATABASE_URL_DIRECT` where set) at one, or start the bundled PostgreSQL from a fresh data volume. A 1.x backup restored onto 2.0 by any route is refused the same way. The API and worker refuse to start against a database that has not applied every migration their image ships.

Chains, vault dumps and audit exports from a 2.0 Server verify with `@agledger/verify` 2.0.0 or later. Each key at `GET /v1/verification-keys` publishes the floor as `minVerifierVersion`.

A vault signing key is trusted only through signed key statements that link it to a key a process holds outside the database: `VAULT_SIGNING_KEY`, the KMS key, its predecessor, or a `VAULT_TRUST_ANCHORS` pin. A key row the runtime database role inserts verifies no entry and is published on no key surface. To stage a new key, set `VAULT_SIGNING_KEY_PREVIOUS` (or `VAULT_SIGNING_KEY_PREVIOUS_KMS_ARN`) to the running key, which signs the succession. `VAULT_DISTRUSTED_KEYS` lists the pins of keys that leaked, each optionally with the instant from which what it signs counts for nothing. A forced retirement revokes every unexpired ephemeral cert the key minted and reports `revokedCertCount`.

Error bodies carry `detail` as the one human-readable field. `message`, which repeated it, is gone from every Problem Details response, along with `migratedTo`, `docs` and `signInputTemplate`; the JSON-RPC `error.message` on `/a2a` stays. A body 400 lists every independent violation rather than the first.

Vocabulary 1.7.0 removed is now refused rather than translated: an `escalated` dispute action, a `tier` field or a `PENDING_ARBITRATION` state fails body validation, and a provisioning file naming `commissionSourceField` fails as an unknown key. The nine routes 1.7.0 retired and `GET /v1/records/summary` no longer answer 410 with a pointer; they get the ordinary 400 or 404. Use `GET /v1/records/search` in place of the summary. `GET /v1/events` refuses `eventType=record.settled`.

Adds `DELETE /v1/webhooks/{webhookId}/dlq/{dlqId}` and `DELETE /v1/admin/webhook-dlq/{dlqId}`, which discard a dead-lettered delivery without delivering it; on an inactive subscription this is the only way to clear an entry. `DELETE /v1/webhooks/{webhookId}` answers 200 naming the dead letters the subscription still holds, where it answered 204. The webhook ping response carries `statusCode` and `durationMs` without the `httpStatus` and `latencyMs` twins. Record reads take `?view=compact`, which drops top-level nulls and trims `nextSteps`.

Keyset listings page by `nextCursor` alone and refuse `?offset=`. The agent card is served at `/.well-known/agent-card.json` only; `/.well-known/agent.json` is gone. `/a2a` answers the A2A 1.0 PascalCase methods and the A2A 0.3 slash-separated methods, and an `a2a.`-prefixed name such as `a2a.SendMessage` is METHOD_NOT_FOUND. A2A `ListTasks` filters on `status` only.

Opening, adding evidence to, withdrawing and resolving a dispute require the new `disputes:write` scope, which `agent-full` and `admin-standard` carry and `admin-observer` and `agent-readonly` do not. An IdP that asserts an explicit scope list through a trusted issuer must add it.

Federation messages are signed addressed to the receiving Server under `agledger.federation.v2` and require the `X-AGLedger-Recipient-Hub-Id` header. The v1 sign input is neither built nor accepted, so a 2.0 Server does not federate with a 1.x one. Every federation body requires `schemaRef`.

`RATE_LIMIT_AUTH_FAILURES` (default 60, 0 turns it off) caps the refused credentials one source address, or one IPv6 /64, may present per window before its credentialed requests get 429 with no lookup; a credential that already verified from that address is not held back. `/a2a` is limited in operations rather than requests, 200 a minute by default with a batch of N costing N, set by `RATE_LIMIT_A2A_OPS`, and each state-changing action also spends its REST route's cap. `RATE_LIMIT_EXEMPT_IPS` takes CIDR blocks. Self-service API key rotation never extends a key's expiry.

Production refuses an `API_KEY_SECRET` or `WEBHOOK_ENCRYPTION_KEY` shorter than 32 characters or equal to the development fallback. A numeric setting that is not a whole number in its stated range refuses boot, naming the variable, where it fell back to the default. A malformed `SSRF_ALLOW_CIDRS` stops boot, and loopback, unspecified and cloud metadata addresses are refused whatever it says. `SIEM_HTTP_URL` and `AGLEDGER_SUPPORT_BUNDLE_URL` refuse only cloud metadata, so a loopback or private-range collector needs no `SSRF_ALLOW_CIDRS` entry. `TRUST_PROXY=true` boots with a warning that clients can forge their address. Removes `AGLEDGER_LAUNCH_FROZEN` and `AGLEDGER_FEDERATION_SCHEMA_REF_POLICY`.

The image trusts the current AWS RDS global CA bundle, which adds the me-west-1 root CAs.

## v1.8.0 - 2026-09-22

Scripts, Compose files, and Helm chart synced to AGLedger server v1.8.0.

Compose keeps Prometheus series on a named `prometheus-data` volume, bounded at 30 days or 10 GB, so they survive `docker compose down`. The first start on this version begins an empty Prometheus store: the previous store sits on an anonymous volume the new mount no longer reads. Grafana dashboards and the chain are unaffected.

Every shipped alert links to a runbook section in `monitoring/runbooks.md`, and a new `agledger-targets` rule group covers a process that stops being scraped, a failing scrape, restarts and event-loop lag. On Kubernetes, `monitoring.prometheusRule.overrides` retunes a named alert's severity, `for`, `keep_firing_for` or `expr` without forking the file, `monitoring.prometheusRule.runbookUrl` rebases the runbook links, and `config.otelExporterOtlpEndpoint` enables tracing and opens egress to the collector. Dashboards read through `datasource` and `job` variables.

Every release publishes a signed offline-verification bundle, and an air-gapped install verifies a release from bundles carried into the enclave with no registry and no Rekor. `helm-install.sh` takes a chart and an image override, so the guided path works against a mirror. `AGLEDGER_REQUIRE_VERIFY` refuses a mirrored image and outranks `AGLEDGER_SKIP_VERIFY`.

Server changes in v1.8.0:

Staging a vault signing key now activates it beside the keys already active, and retiring one is a separate admin step at `POST /v1/admin/vault/signing-keys/{keyId}/retire`. More than one key can be active at once during a rolling key change, so a consumer of `GET /v1/verification-keys` resolves by `keyId` rather than taking the active one. A process whose key reads retired stops signing, answers 503 on `/health/ready`, and on the worker stops consuming jobs.

The vault signing key can live in AWS KMS: set `VAULT_SIGNING_KEY_KMS_ARN` and no key material is held by the Server. A Sign that fails rolls its write back and answers 503, and repeated failures close a gate that the key watch reopens.

Adds `GET /v1/admin/vault/rewind`, `POST /v1/admin/vault/rewind/acknowledge` and `POST /v1/admin/vault/anchors/reconcile`. External anchors now catch a database that has been rolled back behind a position it already anchored, and the chain refuses writes until an operator acknowledges the rewind.

Removes `environment` from the api-key create body, the create response and the key listing: a live-or-test label on a row in one Server's own database named nothing the engine read. Removes `previousKeyId` from the signing-key rotate response, which no longer describes what rotation does.

A database outage answers 503 naming the dependency, on every door the API serves, rather than a generic error.

The SIEM feed validates against OCSF 1.4.0 and gains an HTTP push sink: `SIEM_HTTP_URL` with `SIEM_HTTP_MODE` of `ndjson` or `hec` for Splunk HEC. A collector that rejects the request is told apart from one that is down, and the file sink follows a logrotate rename-and-create rotation.

`DATABASE_URL_DIRECT` carries LISTEN, the session advisory locks and migrations, so the transactional pool can run through a connection pooler in transaction mode. `WEBHOOK_ENCRYPTION_KEY_PREVIOUS` lets a webhook secret stored under a previous encryption key keep delivering while it is re-encrypted under the current one. `RATE_LIMIT_POST_RECORDS` and `RATE_LIMIT_POST_RECORDS_BULK` make those two caps configurable.

A receiver or peer that answers with `Retry-After` gets the next attempt at the instant it named, and a rate limit no longer walks a healthy subscription to an open circuit breaker.

Migration 008 repairs signing-key activation windows that opened after the entries they cover, and from this release only the retirement path may retire a key. Rolling back to 1.7.0 after a key change leaves that pod logging a warning with a cold verification-key cache; it keeps serving and keeps publishing its keys.

## v1.7.0 — 2026-09-12

Scripts, Compose files, and Helm chart synced to AGLedger server v1.7.0.

Server changes in v1.7.0:

Removes commission tracking: the engine no longer accepts `commissionPct` on a record or `commissionSourceField` on a registered type, and no longer computes or returns `commissionAmount`.

Removes nine routes and answers each with a 410 naming its replacement: counter-proposal (`POST /v1/records/{id}/counter-propose`, `POST /v1/records/{id}/accept-counter`), the dispute tier ladder (`POST /v1/records/{recordId}/dispute/escalate`), agent reputation (`GET /v1/agents/{agentId}/reputation`, `GET /v1/agents/{agentId}/reputation/{type}`, `GET /federation/v1/agents/{agentId}/reputation`, `POST /federation/v1/reputation/contribute`), and the peer agent directory (`POST /federation/v1/peer/agent-sync`, `POST /federation/v1/admin/peers/{peerHubId}/resync`).

Adds agent drift (`GET /v1/agents/drift`, `GET /v1/agents/{agentId}/drift`) in place of the removed reputation score, `POST /v1/disputes/{id}/resolve`, and `POST /v1/admin/agents/{id}/reactivate` and `POST /v1/admin/orgs/{id}/reactivate`.

`/v1/events`, SIEM polling and `GET /v1/agents/{agentId}/history` project record status at read time, including for rows written before this upgrade: `DRAFT` and `REGISTERED` read as `CREATED`, `COMPLETION_ACCEPTED` and `PENDING_VERDICT` read as `PROCESSING`, `COMPLETION_INVALID` reads as `ACTIVE`, `VERDICT_REJECTED` reads as `FAILED`, `TIMED_OUT` reads as `EXPIRED`, and both cancel states read as `CANCELLED` with the distinction carried in `terminalReason`. Migration 007 takes exclusive locks on the record tables and wants a maintenance window.

## v1.6.0 — 2026-08-29

Scripts, Compose files, and Helm chart synced to AGLedger server v1.6.0.


## v1.5.0 — 2026-08-21

Scripts, Compose files, and Helm chart synced to AGLedger server v1.5.0.


- New horizontal recipe: `examples/recipes/work-context/` (Agent Work Context). Durable work state for AI agents: signed checkpoint records under a root, schema-enforced supersedes lineage, cold-start resume/handoff, a client-side lineage checker, and an importable manifest (publisher `agledger-recipes`) alongside the `register.sh` path. Validated against a live v1.4.0 Compose install.

## v1.4.0 — 2026-08-09

Scripts, Compose files, and Helm chart synced to AGLedger server v1.4.0.


## v1.3.4 — 2026-07-27

Scripts, Compose files, and Helm chart synced to AGLedger server v1.3.4.


## v1.3.3 — 2026-07-18

Scripts, Compose files, and Helm chart synced to AGLedger server v1.3.3.


- Removed the telemetry-heartbeat references from the installer text (`install.sh` banner, `SECURITY.md`, `air-gap/README.md`, `README.md`, `compose/.env.example`). There is no telemetry and no phone-home; the earlier text described placeholder scaffolding that has been removed from the server. Ships in the binary with the next server release.

## v1.3.2 — 2026-07-13

Scripts, Compose files, and Helm chart synced to AGLedger server v1.3.2.


## v1.2.0 — 2026-07-04

Scripts, Compose files, and Helm chart synced to AGLedger server v1.2.0.


## v1.1.0 — 2026-06-25

Scripts, Compose files, and Helm chart synced to AGLedger server v1.1.0.


## v1.0.3 — 2026-06-22

Scripts, Compose files, and Helm chart synced to AGLedger server v1.0.3.


## v1.0.2 — 2026-06-11

Scripts, Compose files, and Helm chart synced to AGLedger server v1.0.2.


## v1.0.1 — 2026-06-11

Scripts, Compose files, and Helm chart synced to AGLedger server v1.0.1.


## v1.0.0 — 2026-06-08

Scripts, Compose files, and Helm chart synced to AGLedger server v1.0.0.


## v0.27.9 — 2026-06-08

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.9.


## v0.27.8 — 2026-06-08

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.8.


## v0.27.7 — 2026-06-06

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.7.


## v0.27.6 — 2026-06-04

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.6.


## v0.27.5 — 2026-06-04

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.5.


## v0.27.2 — 2026-06-03

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.2.


## v0.27.1 — 2026-06-02

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.1.


## v0.27.0 — 2026-06-02

Scripts, Compose files, and Helm chart synced to AGLedger server v0.27.0.


## v0.26.5 — 2026-05-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.5.


## v0.26.4 — 2026-05-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.4.


## v0.26.3 — 2026-05-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.3.


## v0.26.2 — 2026-05-28

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.2.


## v0.26.1 — 2026-05-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.1.


## v0.26.0 — 2026-05-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.26.0.


## v0.25.5 — 2026-05-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.5.


## v0.25.4 — 2026-05-26

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.4.


## v0.25.3 — 2026-05-25

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.3.


## v0.25.2 — 2026-05-25

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.2.


## v0.25.1 — 2026-05-24

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.1.


## v0.25.0 — 2026-05-24

Scripts, Compose files, and Helm chart synced to AGLedger server v0.25.0.


## v0.24.1 — 2026-05-22

Scripts, Compose files, and Helm chart synced to AGLedger server v0.24.1.


## v0.24.0 — 2026-05-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.24.0.


## v0.23.9 — 2026-05-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.9.


## v0.23.8 — 2026-05-20

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.8.


## v0.23.7 — 2026-05-20

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.7.


## v0.23.5 — 2026-05-20

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.5.


## v0.23.4 — 2026-05-19

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.4.


## v0.23.3 — 2026-05-19

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.3.


## v0.23.2 — 2026-05-19

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.2.


## v0.23.1 — 2026-05-19

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.1.


## v0.23.0 — 2026-05-19

Scripts, Compose files, and Helm chart synced to AGLedger server v0.23.0.


## v0.22.36 — 2026-05-18

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.36.


## v0.22.34 — 2026-05-18

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.34.


## v0.22.33 — 2026-05-18

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.33.


## v0.22.32 — 2026-05-16

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.32.


## v0.22.31 — 2026-05-11

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.31.


## v0.22.30 — 2026-05-09

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.30.


## v0.22.29 — 2026-05-09

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.29.


## v0.22.28 — 2026-05-09

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.28.


## v0.22.27 — 2026-05-08

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.27.


## v0.22.26 — 2026-05-08

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.26.


## v0.22.25 — 2026-05-07

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.25.


## v0.22.24 — 2026-05-07

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.24.


## v0.22.23 — 2026-05-07

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.23.


## v0.22.22 — 2026-05-07

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.22.


## vv0.22.20 — 2026-05-06

Scripts, Compose files, and Helm chart synced to AGLedger server vv0.22.20.


## v0.22.19 — 2026-05-06

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.19.


## v0.22.18 — 2026-05-02

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.18.


## v0.22.17 — 2026-05-01

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.17.


## v0.22.15 — 2026-05-01

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.15.


## v0.22.14 — 2026-05-01

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.14.


## v0.22.13 — 2026-05-01

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.13.


## v0.22.12 — 2026-05-01

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.12.


## v0.22.11 — 2026-04-30

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.11.


## v0.22.10 — 2026-04-30

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.10.


## v0.22.9 — 2026-04-30

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.9.


## v0.22.8 — 2026-04-30

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.8.


## v0.22.7 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.7.


## v0.22.6 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.6.


## v0.22.5 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.5.


## v0.22.4 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.4.


## v0.22.3 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.3.


## v0.22.1 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.1.


## v0.22.0 — 2026-04-29

Scripts, Compose files, and Helm chart synced to AGLedger server v0.22.0.


## v0.21.7 — 2026-04-28

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.7.


## v0.21.6 — 2026-04-28

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.6.


## v0.21.5 — 2026-04-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.5.


## v0.21.4 — 2026-04-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.4.


## v0.21.3 — 2026-04-27

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.3.


## v0.21.2 — 2026-04-25

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.2.


## v0.21.1 — 2026-04-25

Scripts, Compose files, and Helm chart synced to AGLedger server v0.21.1.


## v0.20.4 — 2026-04-24

Scripts, Compose files, and Helm chart synced to AGLedger server v0.20.4.


## v0.20.3 — 2026-04-24

Scripts, Compose files, and Helm chart synced to AGLedger server v0.20.3.


## v0.20.2 — 2026-04-23

Scripts, Compose files, and Helm chart synced to AGLedger server v0.20.2.


## v0.20.1 — 2026-04-23

Scripts, Compose files, and Helm chart synced to AGLedger server v0.20.1.


## v0.20.0 — 2026-04-23

Scripts, Compose files, and Helm chart synced to AGLedger server v0.20.0.


## v0.19.26 — 2026-04-22

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.26.


## v0.19.25 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.25.


## v0.19.24 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.24.


## v0.19.23 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.23.


## v0.19.22 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.22.


## v0.19.21 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.21.


## v0.19.20 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.20.


## v0.19.19 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.19.


## v0.19.18 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.18.


## v0.19.17 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.17.


## v0.19.16 — 2026-04-21

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.16.


## v0.19.15 — 2026-04-20

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.15.


## v0.19.14 — 2026-04-20

Scripts, Compose files, and Helm chart synced to AGLedger server v0.19.14.


- Initial public release. Install scripts, Docker Compose files, Helm chart, and supply-chain artifacts moved from the private `agledger-api/deploy` tree to this repository.
- `install.sh` resolves the default version from the live Docker Hub tag list rather than a hardcoded string, so fresh clones always install the current stable release.
