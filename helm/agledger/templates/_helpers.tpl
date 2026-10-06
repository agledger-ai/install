{{/*
Expand the name of the chart.
*/}}
{{- define "agledger.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this.
*/}}
{{- define "agledger.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "agledger.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "agledger.labels" -}}
helm.sh/chart: {{ include "agledger.chart" . }}
{{ include "agledger.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "agledger.selectorLabels" -}}
app.kubernetes.io/name: {{ include "agledger.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Build the full image reference from values.

If `image.digest` is set, it is concatenated as `repository@sha256:...` and the
tag is omitted from the rendered reference (kubelet resolves by content hash,
ignoring any tag drift). The mutable-tag `IfNotPresent` cache trap — where a
node keeps an older image because something is already tagged with the same
name — is bypassed entirely. For production, prefer pinning by digest.

Otherwise the reference is `repository:tag` (tag defaults to Chart.AppVersion).
*/}}
{{- define "agledger.image" -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end -}}
{{- end }}

{{/*
The post-restore CronJob's name, which is also the name of the Secret its Job
reads. 52 characters: the CronJob controller refuses a longer name, because the
Jobs it would create append eleven.
*/}}
{{- define "agledger.postRestoreName" -}}
{{- printf "%s-post-restore" (include "agledger.fullname" .) | trunc 52 | trimSuffix "-" }}
{{- end }}

{{/*
Service account name.
*/}}
{{- define "agledger.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "agledger.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Whether pods running as the chart's service account mount its API token.
False unless serviceAccount.automountToken says otherwise: nothing in the image
calls the Kubernetes API, so a mounted token is a credential a compromised
process could use and nothing else. IRSA and EKS Pod Identity inject their own
projected token and do not need this one. Rendered on the pod spec, where it
wins over whatever the ServiceAccount says, so an existing account named by
serviceAccount.name is covered too.
*/}}
{{- define "agledger.automountToken" -}}
{{- if ((.Values.serviceAccount).automountToken) }}true{{ else }}false{{ end }}
{{- end }}

{{/*
Secret name — either the user-supplied existing secret or the chart-generated one.
*/}}
{{- define "agledger.secretName" -}}
{{- if .Values.secrets.existingSecret }}
{{- .Values.secrets.existingSecret }}
{{- else }}
{{- include "agledger.fullname" . }}
{{- end }}
{{- end }}

{{/*
License file volumeMount (use inside container.volumeMounts).

A directory, not a subPath mount of the file: kubelet never refreshes a subPath
projection, so a rotated license Secret followed by POST /v1/admin/license/reload
(which re-reads AGLEDGER_LICENSE_KEY_FILE for exactly that case) would read the
original bytes for the life of the pod. The env var points at the file inside
the directory; see configmap.yaml.
*/}}
{{- define "agledger.licenseVolumeMount" -}}
{{- if ((.Values.license).keyFile).enabled }}
- name: license
  mountPath: {{ ((.Values.license).keyFile).mountPath | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
License file volume (use inside pod.volumes). Projects only secretKey so other
keys in a shared Secret do not land in the directory.
*/}}
{{- define "agledger.licenseVolume" -}}
{{- if ((.Values.license).keyFile).enabled }}
- name: license
  secret:
    secretName: {{ ((.Values.license).keyFile).secretName | quote }}
    defaultMode: 292  # 0444
    items:
      - key: {{ ((.Values.license).keyFile).secretKey | quote }}
        path: {{ ((.Values.license).keyFile).secretKey | quote }}
{{- end }}
{{- end }}

{{/*
DATABASE_IDLE_IN_TX_TIMEOUT_MS.

Presence, not truthiness: 0 is falsy in Go templates and is also the documented
"disable the idle-in-transaction auto-rollback" value, so `| default 30000`
reads an explicit 0 as unset and re-arms the timeout the operator turned off.

`int` is a cast, not a parse: it swallows conversion errors and returns 0, and
it overflows a too-large number into a negative. The API sets this value as a
Postgres session parameter, where 0 means off and a negative is rejected, so a
malformed value that silently became 0 would disable the guard while the API
logs nothing. Check the kind first and refuse anything that is not a whole
number of milliseconds.
*/}}
{{- define "agledger.idleInTxTimeoutMs" -}}
{{- $raw := .Values.database.idleInTxTimeoutMs -}}
{{- $ms := 30000 -}}
{{- if not (kindIs "invalid" $raw) -}}
{{- if or (kindIs "float64" $raw) (kindIs "int64" $raw) (kindIs "int" $raw) -}}
{{- $ms = int $raw -}}
{{- else if and (kindIs "string" $raw) (regexMatch "^[0-9]+$" $raw) -}}
{{- $ms = int $raw -}}
{{- else -}}
{{- fail (printf "database.idleInTxTimeoutMs must be a whole number of milliseconds, not %#v (%s). No unit suffix: write 30000, not \"30s\". Set 0 to disable the idle-in-transaction auto-rollback." $raw (kindOf $raw)) -}}
{{- end -}}
{{- if lt $ms 0 -}}
{{- fail (printf "database.idleInTxTimeoutMs must be zero or positive, and %#v is out of range for a 64-bit millisecond count. It renders into `SET idle_in_transaction_session_timeout`; 0 disables the auto-rollback." $raw) -}}
{{- end -}}
{{- end -}}
{{- $ms -}}
{{- end -}}

{{/*
A whole number from 1 to `max`, rendered as digits.

`| quote` on a number prints it the way Go prints a float64, which is how YAML
numbers reach a template: 200000 renders "2e+05", which the API refuses at
boot, as it refuses any setting that is not a whole number. So the value is
kind-checked as the timeout helpers above check theirs and rendered through
`int64`. Takes a dict: `value`; `name`, the values path the error names; and
`max`, the ceiling the API's NUMERIC_SETTINGS gives the variable.
*/}}
{{- define "agledger.positiveWholeNumber" -}}
{{- $raw := .value -}}
{{- $n := 0 -}}
{{- if or (kindIs "int64" $raw) (kindIs "int" $raw) -}}
{{- $n = int64 $raw -}}
{{- else if and (kindIs "float64" $raw) (eq (float64 (int64 $raw)) $raw) -}}
{{- $n = int64 $raw -}}
{{- else if and (kindIs "string" $raw) (regexMatch "^[0-9]+$" $raw) -}}
{{- $n = int64 $raw -}}
{{- else -}}
{{- fail (printf "%s must be a whole number, not %#v (%s)." .name $raw (kindOf $raw)) -}}
{{- end -}}
{{- if or (lt $n 1) (gt $n (int64 .max)) -}}
{{- fail (printf "%s must be a whole number from 1 to %d, not %#v." .name (int64 .max) $raw) -}}
{{- end -}}
{{- $n -}}
{{- end -}}

{{/*
DATABASE_STATEMENT_TIMEOUT_MS.

Same presence-not-truthiness and kind-checking rules as the idle-in-tx helper
above, and for the same reason: 0 is falsy in Go templates and is also a
meaningful value here.

0 does NOT mean "no cap". It means the API sends no `SET statement_timeout`, so
every pooled session inherits the SERVER's setting — and the bundled Postgres
below sets one. Pin a value here to be independent of the server.
*/}}
{{- define "agledger.statementTimeoutMs" -}}
{{- $raw := .Values.database.statementTimeoutMs -}}
{{- $ms := 0 -}}
{{- if not (kindIs "invalid" $raw) -}}
{{- if or (kindIs "float64" $raw) (kindIs "int64" $raw) (kindIs "int" $raw) -}}
{{- $ms = int $raw -}}
{{- else if and (kindIs "string" $raw) (regexMatch "^[0-9]+$" $raw) -}}
{{- $ms = int $raw -}}
{{- else -}}
{{- fail (printf "database.statementTimeoutMs must be a whole number of milliseconds, not %#v (%s). No unit suffix: write 30000, not \"30s\". Set 0 to inherit the server's statement_timeout." $raw (kindOf $raw)) -}}
{{- end -}}
{{- if lt $ms 0 -}}
{{- fail (printf "database.statementTimeoutMs must be zero or positive, and %#v is out of range for a 64-bit millisecond count. It renders into `SET statement_timeout`; 0 inherits the server's setting." $raw) -}}
{{- end -}}
{{- end -}}
{{- $ms -}}
{{- end -}}

{{/*
Refuse a values file that nulls a block the chart cannot render without.

`<block>: null` is the documented Helm idiom for dropping a default map, and a
key whose body is commented out parses the same way. For an optional-feature
block (ingress, hpa, provisioning, license, marketplace, signing, openshift, postgres)
that reads as "not using this", and the chart renders with the feature off. For
the two groups below it does not, so the operator has to say what they meant:

  - permission, networkPolicy and pdb ship ENABLED. A nil block is
    indistinguishable from `enabled: false` at the lookup, so tolerating it
    would ship the Node Permission Model sandbox off, or with no NetworkPolicy,
    or with no PodDisruptionBudget, and nothing in the rendered output would
    say so.
  - the rest carry settings every workload reads. There is no coherent "off"
    to fall back to.

Included from configmap.yaml (always rendered) and from permissionArgs (reached
by both workloads), so the message names the block instead of surfacing as a
nil-pointer deref from whichever template Helm happened to render first.
*/}}
{{- define "agledger.validateValues" -}}
{{- range $block := list "permission" "networkPolicy" "pdb" "postRestore" -}}
{{- if kindIs "invalid" (index $.Values $block) -}}
{{- fail (printf "%s is null. That block ships enabled, and a null one is indistinguishable from %s.enabled=false, so the chart would render with the feature off and say nothing about it. Set %s.enabled explicitly (true to keep the shipped default, false to drop it) rather than nulling the block." $block $block $block) -}}
{{- end -}}
{{- end -}}
{{- range $block := list "image" "api" "worker" "migrate" "database" "secrets" "config" "serviceAccount" -}}
{{- if kindIs "invalid" (index $.Values $block) -}}
{{- fail (printf "%s is null. Every workload reads settings out of that block, so there is no \"off\" for the chart to fall back to. Override the keys you need under %s rather than nulling the block." $block $block) -}}
{{- end -}}
{{- end -}}
{{- range (concat ($.Values.extraEnv | default list) (($.Values.migrate).extraEnv | default list)) -}}
{{- if eq (.name | default "") "AGLEDGER_INSTANCE_ID" -}}
{{- fail "extraEnv sets AGLEDGER_INSTANCE_ID, which the chart already supplies through its ConfigMap from the instanceId value. Kubernetes keeps both, an explicit env entry wins over envFrom, and the pods would anchor under a prefix the ConfigMap does not name. Move the value to instanceId and drop the extraEnv entry." -}}
{{- end -}}
{{- end -}}
{{- if (include "agledger.bundledPostgres" $) -}}
{{- $running := lookup "apps/v1" "Deployment" $.Release.Namespace (printf "%s-api" (include "agledger.fullname" $)) | default dict -}}
{{- $pgdata := lookup "v1" "PersistentVolumeClaim" $.Release.Namespace (printf "%s-pgdata" (include "agledger.fullname" $)) | default dict -}}
{{- $labels := ($running.metadata).labels | default dict -}}
{{- if $pgdata -}}
{{- include "agledger.refuseReleaseLineCrossing" (dict "installed" (get $labels "app.kubernetes.io/version") "target" $.Chart.AppVersion "release" $.Release.Name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
A bundled-PostgreSQL release a 1.x chart installed is refused at render, before
Helm touches anything. Its database lives in the release's own volume, so the
2.x migration would refuse it, and by then the upgrade has already replaced
the Recreate-strategy pods and rewritten the hook Secret, which `helm rollback`
does not restore. An external database is not refused here: its migrate Job is
a pre-upgrade hook that fails before any pod is replaced, and the operator may
be pointing the release at a new, empty database.

`installed` is the running api Deployment's app.kubernetes.io/version label,
empty on a first install and under a renderer, where `lookup` answers nothing.
It is asked only when the bundled data volume already exists: a 1.x release on
an external database that turns the bundled path on gets a new, empty volume,
which 2.x migrates.
*/}}
{{- define "agledger.refuseReleaseLineCrossing" -}}
{{- $installed := .installed | default "" | trimPrefix "v" -}}
{{- $target := .target | default "" | trimPrefix "v" -}}
{{- if and (eq (first (splitList "." $installed)) "1") (regexMatch "^[0-9]+\\." $target) (ge (atoi (first (splitList "." $target))) 2) -}}
{{- fail (printf "Release %s runs AGLedger %s on the bundled PostgreSQL, and chart %s does not upgrade a 1.x database in place: its migration refuses the database a 1.x release migrated. Nothing was changed, and %s keeps serving. To run %s, install it as a new release, which gets its own bundled database (helm install %s-2 ..., without this release's fullnameOverride or existingSecret), and keep this release for its data." .release $installed $target $installed $target .release) -}}
{{- end -}}
{{- end -}}

{{/*
The Server's published identity — AGLEDGER_EXTERNAL_URL.

This is the `iss` signed into every record, receipt and certificate. Rows
already written carry it forever: changing it later does not rewrite them, it
splits the chain into two issuers, and an offline verifier reading the old rows
still resolves keys against the old one. So it is resolved once, here, and both
the ConfigMap and NOTES.txt read the same answer.

Resolution order: explicit config.externalUrl, then the first ingress host
(https when TLS or an ALB certificate is configured, http otherwise), then
route.host (https when route.tls.enabled). Ingress and Route cannot both be
on, so the last two never compete.

With neither, a production render is refused rather than defaulted. A
fallback would sign `https://localhost` into a permanent field on an install
whose operator was never asked, and nothing in the output would say so. Non-production
keeps the fallback so `helm install` on a dev cluster still boots.

The refusal is worded twice, because an install and an upgrade need opposite
advice. On an install the operator is choosing an issuer, and the public
URL is the right answer. On an upgrade they already HAVE one, very likely the
old `https://localhost` fallback, and the public URL is the one value that
splits the chain. The upgrade branch names where to read the current issuer
instead of offering a new one.

`.Release.IsUpgrade` is false under `helm template`, which is how Argo CD and
every other rendering GitOps tool invokes this chart, so an existing Argo
release that trips this gets the INSTALL wording. That is why the install branch
carries the "if this release already exists" paragraph as well: the two branches
differ in emphasis, and neither may be unsafe on its own.
*/}}
{{- define "agledger.externalUrl" -}}
{{- $extUrl := .Values.config.externalUrl -}}
{{- if and (not $extUrl) (.Values.ingress).enabled (gt (len ((.Values.ingress).hosts | default list)) 0) -}}
{{- $firstHost := (index .Values.ingress.hosts 0).host -}}
{{- $hasAlbSsl := hasKey ((.Values.ingress).annotations | default dict) "alb.ingress.kubernetes.io/certificate-arn" -}}
{{- /* `allowPlainHttp` says TLS terminates in FRONT of this Ingress: a service
       mesh, or a load balancer holding the certificate and speaking HTTP to the
       cluster. The public URL in that arrangement is https, and this value is
       the permanent `iss` of every record, so reading the missing `tls` block
       as http would sign a scheme the Server is not reached on. Same reasoning
       as $hasAlbSsl above, which is one concrete instance of it. */}}
{{- $scheme := ternary "https" "http" (or (gt (len ((.Values.ingress).tls | default list)) 0) $hasAlbSsl ((.Values.ingress).allowPlainHttp)) -}}
{{- $extUrl = printf "%s://%s" $scheme $firstHost -}}
{{- end -}}
{{- if and (not $extUrl) (.Values.route).enabled ((.Values.route).host) -}}
{{- $extUrl = printf "%s://%s" (ternary "https" "http" (((.Values.route).tls).enabled | default false)) .Values.route.host -}}
{{- end -}}
{{- if not $extUrl -}}
{{- if eq .Values.config.nodeEnv "production" -}}
{{- if .Release.IsUpgrade -}}
{{- fail (printf "config.externalUrl is not set and nothing else supplies one, and this is an UPGRADE, so this install already has an issuer.\n\nAGLEDGER_EXTERNAL_URL is the issuer (`iss`) signed into every record, receipt and certificate already written. Those rows keep the issuer they were signed with. Setting a DIFFERENT value now does not correct them, it splits the chain into two issuers, and an offline verifier reading the old rows still resolves keys against the old one.\n\nRead what this install actually uses, and set exactly that:\n  kubectl -n %s get configmap %s -o jsonpath='{.data.AGLEDGER_EXTERNAL_URL}'\n  --set config.externalUrl=<the value that prints>\n\nGET /v1/records/{id} on any existing record answers it too: the `iss` of its signed envelope. Choose a new value only if you intend a new issuer and accept that the chain splits at this upgrade." .Release.Namespace (include "agledger.fullname" .)) -}}
{{- else -}}
{{- fail (printf "config.externalUrl is not set and nothing else supplies one. It becomes AGLEDGER_EXTERNAL_URL, the issuer (`iss`) signed into every record, receipt and certificate this Server writes, and it is permanent: rows already signed keep the issuer they were signed with, so changing it later splits the chain rather than correcting it. Set the public URL this Server will be reachable at:\n  --set config.externalUrl=https://agledger.example.com\nAn ingress host or a route.host answers it too. For a single node with no domain, say so explicitly:\n  --set config.externalUrl=https://localhost\n\nIf this release ALREADY EXISTS (a GitOps renderer such as Argo CD runs `helm template`, which cannot tell an upgrade from an install), read the issuer it is already signing with and set exactly that, rather than choosing a new one here:\n  kubectl -n %s get configmap %s -o jsonpath='{.data.AGLEDGER_EXTERNAL_URL}'" .Release.Namespace (include "agledger.fullname" .)) -}}
{{- end -}}
{{- else -}}
{{- $extUrl = "https://localhost" -}}
{{- end -}}
{{- end -}}
{{- $extUrl -}}
{{- end -}}

{{/*
Node 24 Permission Model argv prefix. Emits a comma-terminated list of quoted
node argv entries (`"--permission", "--allow-fs-read=*", ...`) to prepend before
the entry script in a container command/args array. Empty when
`permission.enabled` is false. `permission.extraAllowArgs` widens the sandbox
(e.g. `--allow-fs-write=/var/log/agledger` for the file SIEM sink).
*/}}
{{- define "agledger.permissionArgs" -}}
{{- include "agledger.validateValues" . -}}
{{- if .Values.permission.enabled -}}
"--permission", "--allow-fs-read=*", {{ range .Values.permission.extraAllowArgs }}{{ . | quote }}, {{ end }}
{{- end -}}
{{- end -}}

{{/*
Extra environment entries (use inside container.env).

Rendered entry by entry rather than with a bare `toYaml` over the whole list.
Helm's `--set extraEnv[0].value=500` yields an int64 and `...=true` a bool, but a
Kubernetes EnvVar `value` must be a string, so a whole-list `toYaml` passes the
native type through and the apiserver rejects the apply with "expected string,
got &value.valueUnstructured". Quoting here means `--set` works
without `--set-string`.

`value` and `valueFrom` are branched, never both emitted: an empty `value`
alongside a `valueFrom` is rejected as "may not have more than one field
specified". EnvVar carries exactly name/value/valueFrom, so this covers the type.
*/}}
{{- define "agledger.envList" -}}
{{- range . }}
- name: {{ .name | quote }}
  {{- if hasKey . "value" }}
  {{- /* A YAML number reaches a template as a float64, and `quote` prints
  one of a million or more in exponent form ("2.097152e+06"), which the API
  refuses for a numeric setting. A whole number renders as its digits. */}}
  {{- if and (kindIs "float64" .value) (eq (float64 (int64 .value)) .value) }}
  value: {{ int64 .value | quote }}
  {{- else }}
  value: {{ .value | quote }}
  {{- end }}
  {{- end }}
  {{- with .valueFrom }}
  valueFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}

{{/* The api/worker list. `migrate.extraEnv` renders through the same helper —
the migration pod's env is a separate list (its knobs are migrate-only) but it
must not be a separate implementation of the quoting rule above.

Call sites pipe through `trim` before `nindent`: the range above opens each
entry with a newline, so `nindent` alone leaves a whitespace-only line under
`env:`. Valid YAML, but it shows up in every `helm template` an operator reads.
*/}}
{{/*
The owner-role credentials the chart's Secret carries on the bundled path,
cleared for the api and worker. Both load the whole Secret through envFrom, so
without these they would hold POSTGRES_PASSWORD and DATABASE_URL_MIGRATE, the
superuser's password and URL, though they connect as agledger_app and never
read either. An explicit `env` entry wins over envFrom, so an empty value here
is what the process sees. The migration Job, the backup and Postgres keep them.
*/}}
{{- define "agledger.ownerCredentialClears" -}}
{{- if and (include "agledger.bundledPostgres" .) (not .Values.secrets.existingSecret) }}
- name: POSTGRES_PASSWORD
  value: ""
- name: DATABASE_URL_MIGRATE
  value: ""
{{- end }}
{{- end }}

{{- define "agledger.extraEnv" -}}
{{- include "agledger.envList" .Values.extraEnv -}}
{{- end }}

{{/*
Refuse a DATABASE_URL that arrives through two channels at once.

Every workload consumes the chart's Secret through `envFrom`, and that Secret
carries DATABASE_URL on both managed paths (`database.externalUrl` and bundled
Postgres). An `extraEnv` entry of the same name is then a second channel:
Kubernetes does not reject the duplicate, an explicit `env` entry beats
`envFrom`, and the render says none of it, so the workload quietly talks to a
database no other part of the release names.

Only fires where the chart KNOWS the Secret supplies the variable. Under
`secrets.existingSecret` the operator owns those keys, and `extraEnv` may be
the only channel there, so the guard stays out of the way.

Usage: {{- include "agledger.assertNoDuplicateDatabaseUrl" (dict "envList" .Values.extraEnv "field" "extraEnv" "source" "the chart's Secret") }}
*/}}
{{- define "agledger.assertNoDuplicateDatabaseUrl" -}}
{{- $field := .field -}}
{{- $source := .source -}}
{{- range .envList }}
{{- if eq .name "DATABASE_URL" }}
{{- fail (printf "%s sets DATABASE_URL while %s also supplies it. Kubernetes keeps both, an explicit env entry wins over envFrom, and nothing in the rendered manifest says so. This workload would run against a database the rest of the release never names. Pick one channel: drop the DATABASE_URL entry from %s, or set the connection string where the release already reads it (database.externalUrl, or secrets.databaseUrlMigrate for the migration Job)." $field $source $field) }}
{{- end }}
{{- end }}
{{- end }}

{{/*
True (non-empty) when this release runs the chart's bundled PostgreSQL.

`database.externalUrl` wins over `postgres.bundled.enabled`. Setting both is
reachable (a values file that pinned the bundled flag, or a release reconciled
from bundled to an external database with `--reset-then-reuse-values`, which
carries the old flag forward), and honouring both is what breaks the install:
secret.yaml writes DATABASE_URL from the external URL and reaches its
POSTGRES_PASSWORD branch only on the bundled one, so the bundled Deployment asks
for a Secret key the chart never wrote and sits in CreateContainerConfigError
behind a provisioned PVC; the migration Job waits on
that pod instead of running as a hook; the NetworkPolicy allows database egress
in-cluster only, which an external database is not; ALLOW_DB_WITHOUT_SSL drops
the production TLS requirement on it; and NOTES.txt reports a database the API
never connects to.

Every template that branches on the bundled path reads this, so the precedence
is decided in one place. Empty string is false to `if`.
*/}}
{{- define "agledger.bundledPostgres" -}}
{{- if and (((.Values.postgres).bundled).enabled) (not (.Values.database).externalUrl) }}true{{ end }}
{{- end }}

{{/*
True (non-empty) when the chart's own Secret carries DATABASE_URL.
*/}}
{{- define "agledger.chartSuppliesDatabaseUrl" -}}
{{- if not .Values.secrets.existingSecret }}
{{- if or .Values.database.externalUrl (include "agledger.bundledPostgres" .) }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Provisioning ConfigMap name (chart-generated).
*/}}
{{- define "agledger.provisioningConfigMapName" -}}
{{- printf "%s-provisioning" (include "agledger.fullname" .) }}
{{- end }}

{{/*
Provisioning volumeMounts (use inside container.volumeMounts).
Mounts each subdirectory from its ConfigMap.
*/}}
{{- define "agledger.provisioningVolumeMounts" -}}
{{- if (.Values.provisioning).enabled }}
{{- /* Keep in sync with provisioningVolumes and provisioning-configmap.yaml */ -}}
{{- $subdirs := list "orgs" "agents" "webhooks" "schemas" }}
{{- range $subdir := $subdirs }}
- name: provisioning-{{ $subdir }}
  mountPath: {{ $.Values.provisioning.configPath }}/{{ $subdir }}
  readOnly: true
{{- end }}
{{- /* trusted-issuers.yaml is projected into its OWN subdirectory,
       ${PROVISIONING_CONFIG_PATH}/trusted-issuers/, and the loader accepts the
       file at either that path or the provisioning root.

       A directory, not a subPath mount of the file: kubelet never refreshes a
       subPath projection, so an operator editing the ConfigMap and calling
       POST /v1/admin/provisioning/reload read the original bytes for the life
       of the pod and got a 200 with a clean report. A whole-directory mount at
       the ROOT is not an option either, since it would shadow the four
       subdirectory mounts above; its own subdirectory is what leaves both
       working. Rendered only when there is content to project. */}}
{{- if or (($.Values.provisioning).trustedIssuers) ((($.Values.provisioning).existingConfigMaps | default dict).trustedIssuers) }}
- name: provisioning-trusted-issuers
  mountPath: {{ $.Values.provisioning.configPath }}/trusted-issuers
  readOnly: true
{{- end }}
{{- end }}
{{- end }}

{{/*
Provisioning volumes (use inside pod.volumes).

Two modes per subdirectory:
  1. existingConfigMaps.<subdir> is set → mount that ConfigMap directly
  2. Otherwise → mount the chart-generated ConfigMap with items filtering
     (keys use "subdir--filename.yaml" convention, remapped to bare filenames)
*/}}
{{- define "agledger.provisioningVolumes" -}}
{{- if (.Values.provisioning).enabled }}
{{- $chartCM := include "agledger.provisioningConfigMapName" . }}
{{- /* Keep in sync with provisioningVolumeMounts and provisioning-configmap.yaml */ -}}
{{- $subdirs := list "orgs" "agents" "webhooks" "schemas" }}
{{- range $subdir := $subdirs }}
{{- $existingCM := index (($.Values.provisioning).existingConfigMaps | default dict) $subdir }}
{{- $inline := index $.Values.provisioning $subdir }}
- name: provisioning-{{ $subdir }}
  {{- if $existingCM }}
  configMap:
    name: {{ $existingCM }}
    defaultMode: 292  # 0444
    optional: true
  {{- else if $inline }}
  configMap:
    name: {{ $chartCM }}
    defaultMode: 292  # 0444
    optional: true
    items:
      {{- range $key, $_ := $inline }}
      - key: {{ $subdir }}--{{ $key }}
        path: {{ $key }}
      {{- end }}
  {{- else }}
  {{- /*
    Nothing to project into this subdirectory. It still has to EXIST, because
    the loader is pointed at the parent and a missing parent is a boot error —
    but it must be empty. Mounting the chart ConfigMap here without an `items`
    filter projects EVERY key into it: `kubelet` treats an empty items list the
    same as an absent one, so a chart with orgs and nothing else wrote
    orgs--my-corp.yaml into agents/, webhooks/ and schemas/ as well, and the
    Server booted "completed with errors" reporting three missing-array
    failures against files the operator never wrote.
  */}}
  emptyDir: {}
  {{- end }}
{{- end }}
{{- $issuersCM := (($.Values.provisioning).existingConfigMaps | default dict).trustedIssuers }}
{{- if or (($.Values.provisioning).trustedIssuers) $issuersCM }}
- name: provisioning-trusted-issuers
  configMap:
    name: {{ $issuersCM | default $chartCM }}
    defaultMode: 292  # 0444
    items:
      - key: trusted-issuers.yaml
        path: trusted-issuers.yaml
{{- end }}
{{- end }}
{{- end }}

{{/*
Backup pod template — shared by the CronJob and the pre-upgrade hook Job.

Produces the SAME archive shape deploy/scripts/restore.sh reads:
`backup-<UTC timestamp>.tar.gz` holding `<timestamp>/db.dump` (pg_dump custom
format), `<timestamp>/vault-public-keys.csv` and `<timestamp>/backup-metadata`
(its `created_at`, the instant the dump started). A Kubernetes backup a customer
cannot hand to the documented restore path is not a backup.

It also runs the same PGDMP header check the script does, for the same reason:
both ways this file has been silently unreadable (bytes ahead of the archive,
or no archive at all) are invisible at write time and are discovered at restore
time, which is after the database has been dropped.

Usage: {{- include "agledger.backupPodTemplate" (dict "root" . "component" "backup") }}
*/}}
{{- define "agledger.backupPodTemplate" -}}
{{- $root := .root -}}
{{- $backup := $root.Values.backup | default dict -}}
{{- $s3 := $backup.s3 | default dict -}}
{{- $persist := $backup.persistence | default dict -}}
{{- $keep := $backup.keep | default 7 -}}
metadata:
  labels:
    {{- include "agledger.selectorLabels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  restartPolicy: Never
  serviceAccountName: {{ include "agledger.serviceAccountName" $root }}
  automountServiceAccountToken: {{ include "agledger.automountToken" $root }}
  {{- with $root.Values.image.pullSecrets }}
  imagePullSecrets:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if not ($root.Values.openshift).enabled }}
  {{- with $root.Values.api.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
  containers:
    - name: dump
      {{- /* A PostgreSQL client image, not the AGLedger image: the runtime base
             carries no pg_dump. pg_dump refuses a server NEWER than itself, so
             this tracks the bundled version and an external Postgres 18 needs
             an 18 client here. */}}
      image: {{ $backup.image | default ((($root.Values).postgres).bundled).image | default "postgres:18-alpine@sha256:77f585114c32fbca283dc835b0596f4e52b51b4c6662d7810b2f4084f60a1873" }}
      imagePullPolicy: {{ $root.Values.image.pullPolicy }}
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ include "agledger.secretName" $root }}
              key: DATABASE_URL
        {{- /* On a role-separated install the runtime role holds DML only, and
               pg_dump needs to read every object it is asked to dump. The owner
               URL is already in the Secret for the migration Job; use it here
               when it exists. `optional` so the key's absence leaves the
               variable unset rather than blocking the pod. */}}
        - name: DATABASE_URL_MIGRATE
          valueFrom:
            secretKeyRef:
              name: {{ include "agledger.secretName" $root }}
              key: DATABASE_URL_MIGRATE
              optional: true
        - name: KEEP
          value: {{ $keep | quote }}
      command: ["/bin/sh", "-eu", "-c"]
      args:
        - |
          TS=$(date -u '+%Y-%m-%d-%H%M%S')
          WORK="/work/${TS}"
          mkdir -p "$WORK"

          # The owner role where the install separates them, the runtime role
          # otherwise. A DML-only role dumps whatever it can read and pg_dump
          # errors on the rest, which fails the Job rather than keeping a
          # partial archive, but the right answer is to connect as the role
          # that can read all of it.
          DB="${DATABASE_URL_MIGRATE:-$DATABASE_URL}"

          # -d with the URI, rather than PG* variables parsed out of it in
          # shell. The credential is in this container's argv only, in its own
          # PID namespace, in a pod whose single container already holds the
          # same Secret in its environment.
          # Read from the database's clock before the dump starts: restore.sh
          # exports the revocations stamped at or after it, and the database
          # stamps them with its own clock, so a pod clock ahead of it, or a
          # stamp taken after the dump, would drop some.
          CREATED_AT=$(psql -d "$DB" -Atc "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"')" | tr -d '[:space:]')
          case "$CREATED_AT" in
            [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
            *) echo "ERROR: could not read the database's clock before the dump. No backup was kept."
               rm -rf "$WORK"
               exit 1 ;;
          esac
          # Which database this is: the cluster's system identifier and the
          # database's OID. restore.sh re-applies revocations made after the
          # backup only out of a database that answers with the same value.
          # Empty when the server will not say; that restore lists the
          # credentials to compare instead.
          DATABASE_TOKEN=$(psql -d "$DB" -Atc "SELECT (pg_control_system()).system_identifier::text || ':' || oid::text FROM pg_database WHERE datname = current_database()" 2>/dev/null | tr -d '[:space:]') || DATABASE_TOKEN=""
          case "$DATABASE_TOKEN" in
            *[!0-9:]*|'') echo "WARN: the database did not report its system identifier and OID; this archive records no database_token."
                          DATABASE_TOKEN="" ;;
          esac
          echo "Dumping to ${WORK}/db.dump"
          pg_dump -Fc -d "$DB" > "${WORK}/db.dump"

          # A backup is worth what a restore can read. PGDMP is the magic of a
          # custom-format archive; anything else means something wrote to the
          # dump's stdout ahead of pg_dump, or pg_dump wrote nothing at all.
          if [ "$(head -c 5 "${WORK}/db.dump")" != "PGDMP" ]; then
            echo "ERROR: ${WORK}/db.dump does not begin with the PGDMP magic of a"
            echo "       PostgreSQL custom-format archive. It begins with:"
            head -c 64 "${WORK}/db.dump" | od -c | head -2
            echo "       No backup was kept."
            rm -rf "$WORK"
            exit 1
          fi

          # The WAL position once the dump has finished: a physical copy of
          # this database taken before then (a snapshot, a point-in-time
          # restore, a clone) is behind it, and restore.sh reads no
          # revocations out of one. Empty when the server will not say.
          WAL_LSN=$(psql -d "$DB" -Atc "SELECT pg_current_wal_lsn()::text" 2>/dev/null | tr -d '[:space:]') || WAL_LSN=""
          case "$WAL_LSN" in
            *[!0-9A-F/]*|'') echo "WARN: the database did not report its WAL position; this archive records no wal_lsn."
                             WAL_LSN="" ;;
          esac

          # The keys restore.sh reads. No version record: the Helm release, not
          # the archive, says which release this install runs.
          {
            echo "# AGLedger backup metadata. Written by the chart's backup Job, read by restore.sh."
            echo "created_at=${CREATED_AT}"
            echo "database_token=${DATABASE_TOKEN}"
            echo "wal_lsn=${WAL_LSN}"
          } > "${WORK}/backup-metadata"

          # Public keys only. Private key material is never in the database.
          psql -d "$DB" -c "COPY (SELECT key_id, public_key, algorithm, status, activated_at, retired_at FROM vault_signing_keys ORDER BY activated_at DESC) TO STDOUT WITH CSV HEADER" \
            > "${WORK}/vault-public-keys.csv" 2>/dev/null \
            || echo "Vault key metadata export skipped (table may not exist)."
          if [ -s "${WORK}/vault-public-keys.csv" ]; then
            case "$(head -1 "${WORK}/vault-public-keys.csv")" in
              key_id,*) : ;;
              *) echo "WARN: vault-public-keys.csv does not start with the expected header; dropping it."
                 rm -f "${WORK}/vault-public-keys.csv" ;;
            esac
          else
            rm -f "${WORK}/vault-public-keys.csv"
          fi

          # Written under a name the retention glob does not match, then moved.
          # `tar` straight to the final name leaves a truncated
          # backup-<ts>.tar.gz behind when the Job is killed mid-write, and
          # retention counts it: `ls -t` keeps the newest N, so an unreadable
          # partial evicts a readable archive. `mv` within one filesystem is
          # atomic, so a backup either exists whole or does not exist.
          TARBALL="{{ if $s3.enabled }}/work{{ else }}/backups{{ end }}/backup-${TS}.tar.gz"
          tar -czf "${TARBALL}.partial" -C /work "$TS"
          mv "${TARBALL}.partial" "$TARBALL"
          rm -rf "$WORK"
          echo "Wrote ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
          {{- if $s3.enabled }}

          # Object storage. Retention is the bucket's lifecycle policy: expiring
          # objects from a Job means the Job holding delete rights on the
          # bucket that holds every backup.
          aws {{ with $s3.endpoint }}--endpoint-url {{ . | quote }} {{ end }}s3 cp "$TARBALL" \
            "s3://{{ $s3.bucket }}/{{ with $s3.prefix }}{{ trimSuffix "/" . }}/{{ end }}backup-${TS}.tar.gz"
          echo "Uploaded to s3://{{ $s3.bucket }}/{{ with $s3.prefix }}{{ trimSuffix "/" . }}/{{ end }}backup-${TS}.tar.gz"
          {{- else }}

          # Keep the newest $KEEP. The glob does not match the `.partial` name
          # above, so a killed Job's leftover is never counted as a backup and
          # never evicts one. It is also never cleaned up here: a `.partial`
          # sitting in the directory is the evidence that a run died, and the
          # next successful run overwrites it.
          echo "Retaining the newest ${KEEP} backups"
          ls -1t /backups/backup-*.tar.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
            echo "Removing $old"
            rm -f "$old"
          done
          {{- end }}
      {{- if $s3.enabled }}
      envFrom:
        {{- /* Credentials for the upload. On EKS with IRSA, or any cluster with
               a workload-identity provider, leave this empty and annotate the
               service account instead. */}}
        {{- with $s3.existingSecret }}
        - secretRef:
            name: {{ . }}
        {{- end }}
      {{- end }}
      volumeMounts:
        - name: work
          mountPath: /work
        {{- if not $s3.enabled }}
        - name: backups
          mountPath: /backups
        {{- end }}
      resources:
        {{- toYaml ($backup.resources | default (dict "requests" (dict "memory" "128Mi" "cpu" "100m") "limits" (dict "memory" "512Mi"))) | nindent 8 }}
  volumes:
    - name: work
      emptyDir:
        sizeLimit: {{ $backup.workDirSize | default "8Gi" }}
    {{- if not $s3.enabled }}
    - name: backups
      persistentVolumeClaim:
        claimName: {{ $persist.existingClaim | default (printf "%s-backups" (include "agledger.fullname" $root)) }}
    {{- end }}
  {{- with $backup.nodeSelector }}
  nodeSelector:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $backup.tolerations }}
  tolerations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end -}}

{{/*
Refuse an API grace period the app's own drain budget does not fit inside.

`preStopSleepSeconds` burns INSIDE `terminationGracePeriodSeconds` (the kubelet
starts the clock, runs the preStop hook, and only then sends SIGTERM), so the
process actually gets `grace - preStop` seconds. On SIGTERM the API meters its
own shutdown against a 25s drain budget and force-exits at it, so anything under
that means the kubelet SIGKILLs mid-drain: in-flight requests severed, the final
SIEM export batch dropped, the database pool never released. Trim the grace
period far enough and the preStop sleep swallows it whole, the process never
receives SIGTERM at all, and every rolling update becomes a hard cut.

Nothing in the rendered manifest shows this arithmetic, which is why it is a
`fail` rather than a NOTES line. `$drain` mirrors the API's own drain budget.

Usage: {{- include "agledger.assertApiGracePeriodFitsDrain" . }}
*/}}
{{- define "agledger.assertApiGracePeriodFitsDrain" -}}
{{- $drain := 25 -}}
{{- $headroom := 5 -}}
{{- $raw := .Values.api.terminationGracePeriodSeconds -}}
{{/* A string here is a unit-suffix typo ("45s"). `int` would silently yield 0
     and the refusal below would quote a number the operator never wrote. */}}
{{- if kindIs "string" $raw -}}
{{- fail (printf "api.terminationGracePeriodSeconds must be a number of seconds, not %q. Kubernetes takes a plain integer here (no unit suffix)." $raw) -}}
{{- end -}}
{{/* Unset or null is legal and means the Kubernetes default, which is 30. Use
     that rather than `int nil` = 0, so the arithmetic below is the arithmetic
     the cluster would actually apply.

     Test for PRESENCE, not truthiness: 0 is falsy in Go templates, so a plain
     `if $raw` would treat an explicit 0 as "unset", evaluate the safe default,
     and render `terminationGracePeriodSeconds: 0`. That is an immediate SIGKILL
     with no SIGTERM at all, the single worst value this guard has to refuse. */}}
{{- $grace := 30 -}}
{{- $source := "the Kubernetes default, because api.terminationGracePeriodSeconds is unset" -}}
{{- if not (kindIs "invalid" $raw) -}}
{{- $grace = int $raw -}}
{{- $source = printf "api.terminationGracePeriodSeconds=%d" $grace -}}
{{- end -}}
{{/* Parenthesized lookup: `api.strategy: null` is the documented Helm idiom for
     dropping a default map, and api-deployment.yaml's `with` already allows it.
     A bare .strategy.type would nil-deref on a values file that renders today. */}}
{{- $preStop := 0 -}}
{{- if eq ((.Values.api.strategy).type | default "") "RollingUpdate" -}}
{{- $preStop = int .Values.api.preStopSleepSeconds -}}
{{- end -}}
{{- $effective := sub $grace $preStop -}}
{{- if lt $effective (add $drain $headroom) -}}
{{- fail (printf "%s leaves the API process only %ds after SIGTERM (preStop sleep of %ds burns inside the grace period), but it drains for up to %ds and needs %ds of headroom. The kubelet would SIGKILL mid-drain: in-flight requests severed, the last SIEM export batch dropped, the database pool never released. Set api.terminationGracePeriodSeconds to at least %d, or lower api.preStopSleepSeconds." $source $effective $preStop $drain $headroom (add (add $drain $headroom) $preStop)) -}}
{{- end -}}
{{- end }}

{{/*
The Secret values the chart may have to supply itself, resolved once per render
into .Values._resolvedSecretValues: API_KEY_SECRET, the bundled-PostgreSQL
owner password and METRICS_AUTH_TOKEN are each the operator's value, else what
the release Secret already carries (read back with `lookup`), else generated.
VAULT_SIGNING_KEY resolves the same way but is never generated, and is empty
under KMS custody (signing.kmsKeyArn), where the process holds no key material.

Once per render, because secret.yaml is rendered twice in one: as the Secret,
and inside the api and worker checksum/secret annotations. Two calls to
randAlphaNum would leave the annotation hashing a value the Secret never
carries, and the next upgrade, reading the real value back, would hash a
different one and roll both Deployments with nothing changed.

`lookup` asks the API server, so it answers only during a real helm install or
upgrade. Under a renderer (Argo CD, or any `helm template | kubectl apply`
pipeline) it returns an empty dict, every sync falls through to the generator,
and the Secret is applied carrying values nothing has seen before: every API
key issued against the previous API_KEY_SECRET stops authenticating, the
bundled-PostgreSQL password stops matching what initdb set, and the Prometheus
the last sync configured starts collecting 401s. From here that is
indistinguishable from a first install, so nothing warns.

There is no in-template flag that separates the two: `.Release.IsInstall` is
true under `helm template` as well. `secrets.gitops` is the operator saying
which one this is, and it turns each fallback below into a render failure
naming what to supply instead. The supported answer is `secrets.existingSecret`,
which skips the chart's Secret entirely.
*/}}
{{- define "agledger.resolveSecretValues" -}}
{{- if not (hasKey .Values "_resolvedSecretValues") -}}
{{- $existingData := (lookup "v1" "Secret" .Release.Namespace (include "agledger.fullname" .)).data | default dict -}}
{{- $gitops := (.Values.secrets).gitops | default false -}}
{{- $apiKeySecret := .Values.secrets.apiKeySecret | default ($existingData.API_KEY_SECRET | default "" | b64dec) -}}
{{- if not $apiKeySecret -}}
  {{- if $gitops -}}
    {{- fail "secrets.gitops is true and secrets.apiKeySecret is unset. API_KEY_SECRET is the HMAC key every API key is hashed under, and a renderer cannot read the value the last sync applied, so generating one here would silently stop every issued key from authenticating. Set secrets.existingSecret to a Secret your platform manages (External Secrets, Sealed Secrets, SOPS) and the chart writes no Secret at all, or pin secrets.apiKeySecret to a value your renderer holds." -}}
  {{- end -}}
  {{- $apiKeySecret = randAlphaNum 64 -}}
{{- end -}}
{{- /* Bundled-PG password: user-provided, then reuse existing, then generate
       (never a static default). */ -}}
{{- $pgPassword := ((.Values.postgres).bundled).password | default ($existingData.POSTGRES_PASSWORD | default "" | b64dec) -}}
{{- if not $pgPassword -}}
  {{- /* Exactly the condition secret.yaml emits POSTGRES_PASSWORD under, and
         it has to stay exactly that: a render that writes no such key must not
         be refused over one, and a render that writes one must not slip past
         the guard. Both read the same helper, so they cannot drift apart. */ -}}
  {{- if and $gitops (include "agledger.bundledPostgres" .) -}}
    {{- fail "secrets.gitops is true and postgres.bundled.password is unset. initdb sets the bundled PostgreSQL password once, from the first Secret it sees, and a renderer cannot read that value back, so generating one here would leave DATABASE_URL carrying a password the database does not have. Set secrets.existingSecret and supply DATABASE_URL yourself, pin postgres.bundled.password, or run an external database." -}}
  {{- end -}}
  {{- $pgPassword = randAlphaNum 32 -}}
{{- end -}}
{{- /* /metrics bearer token. Preserved across upgrades the way apiKeySecret is:
       regenerating it would 401 the Prometheus the last install configured, and
       the scrape failing is invisible until someone looks at a dashboard.
       `secrets.metricsAuthToken: "-"` is the documented way to say "no token"
       for an install that gates /metrics behind the API-key chain instead. */ -}}
{{- $metricsToken := .Values.secrets.metricsAuthToken | default ($existingData.METRICS_AUTH_TOKEN | default "" | b64dec) -}}
{{- if not $metricsToken -}}
  {{- if $gitops -}}
    {{- fail "secrets.gitops is true and secrets.metricsAuthToken is unset. A renderer cannot read the token the last sync applied, so generating one here would 401 the Prometheus already scraping this install, which is invisible until someone looks at a dashboard. Pin secrets.metricsAuthToken, set it to \"-\" to mint none and leave /metrics behind the API-key chain, or set secrets.existingSecret and carry METRICS_AUTH_TOKEN in it." -}}
  {{- end -}}
  {{- $metricsToken = randAlphaNum 48 -}}
{{- end -}}
{{- $vaultSigningKey := "" -}}
{{- if not (.Values.signing).kmsKeyArn -}}
{{- $vaultSigningKey = .Values.secrets.vaultSigningKey | default ($existingData.VAULT_SIGNING_KEY | default "" | b64dec) -}}
{{- end -}}
{{- $_ := set .Values "_resolvedSecretValues" (dict "apiKeySecret" $apiKeySecret "pgPassword" $pgPassword "metricsToken" $metricsToken "vaultSigningKey" $vaultSigningKey) -}}
{{- end -}}
{{- end -}}

{{/*
Checksum of the chart-managed Secret, used as a pod-template annotation so that
changing a secret value rolls the api and worker pods. Without it a Secret-only
change leaves both Deployments running the old values: `envFrom` resolves a
Secret once, at pod start.

It hashes secret.yaml as rendered, the way checksum/config hashes
configmap.yaml, so every key the Secret carries is covered. That is stable
across a no-change upgrade only because the generated values are resolved once
per render (agledger.resolveSecretValues): the annotation hashes the values the
Secret is written with, and the next upgrade reads those same values back.

Empty under `secrets.existingSecret`: the chart writes no Secret then, and
nothing here can see what is in the operator's. Rolling the Deployments after a
change to that Secret is the operator's job, and values.yaml says so.
*/}}
{{- define "agledger.secretChecksum" -}}
{{- if not .Values.secrets.existingSecret -}}
{{- include (print .Template.BasePath "/secret.yaml") . | sha256sum -}}
{{- end -}}
{{- end -}}

{{/*
This Server's AGLEDGER_INSTANCE_ID: the prefix every external anchor key is
written under (`vault-anchors/<id>/`) and, with federation on, the identity
peers store. Two releases on one id and one bucket read each other's anchors.

In order:
  - `instanceId`, when set.
  - The value the release's ConfigMap already carries, read back with `lookup`
    so an upgrade keeps it.
  - `default`, when that ConfigMap exists and carries no id: a release
    installed by a chart that set none, whose Server has anchored under
    `vault-anchors/default/` all along. Minting an id for it would move its
    anchors out of its own reach.
  - A fresh UUID, only when there is no ConfigMap at all: a first install. The
    Server records the first id it boots with in its database and refuses a
    later boot under a different one.

`lookup` answers only during a real install or upgrade. A render that cannot
see the cluster would mint a new id on every sync and the Server would refuse
to boot on the second one, so an unset `instanceId` fails the render wherever
the chart knows it is not in charge of the release's state: `secrets.gitops`,
and `secrets.existingSecret` when `lookup` finds no ConfigMap (a platform that
manages the Secret usually renders the chart too).
*/}}
{{- define "agledger.instanceId" -}}
{{- $pinned := trim (toString (.Values.instanceId | default "")) -}}
{{- if $pinned -}}
{{- $pinned -}}
{{- else -}}
{{- $existing := (lookup "v1" "ConfigMap" .Release.Namespace (include "agledger.fullname" .)) | default dict -}}
{{- $stored := (get ($existing.data | default dict) "AGLEDGER_INSTANCE_ID") | default "" -}}
{{- if $stored -}}
{{- $stored -}}
{{- else if $existing -}}
{{- "default" -}}
{{- else if (.Values.secrets).gitops -}}
{{- fail "secrets.gitops is true and instanceId is unset. AGLEDGER_INSTANCE_ID is the prefix this Server's external anchors are written under, and the Server refuses to boot under an id other than the one its database recorded first. A renderer cannot read the value the last sync applied, so generating one here would mint a new id on every sync. Pin instanceId to a UUID (uuidgen) in the values your renderer holds." -}}
{{- else if (.Values.secrets).existingSecret -}}
{{- fail "secrets.existingSecret is set, instanceId is unset, and this render cannot see a ConfigMap from an earlier install. AGLEDGER_INSTANCE_ID is the prefix this Server's external anchors are written under, and the Server refuses to boot under an id other than the one its database recorded first; a render that cannot read the cluster (Argo CD, helm template) would mint a new one every time. Pin instanceId: a new UUID (uuidgen) for a new install, or, for a release that already runs, the value its ConfigMap or its database carries (the post-restore Job prints it as POST_RESTORE_INSTANCE_ID)." -}}
{{- else -}}
{{- /* One id per render: the ConfigMap and the checksum/config annotation
       that hashes it both come through here, and two different ids would
       leave the annotation hashing a ConfigMap that was never applied. */ -}}
{{- if not (hasKey .Values "_generatedInstanceId") -}}
{{- $_ := set .Values "_generatedInstanceId" (uuidv4) -}}
{{- end -}}
{{- get .Values "_generatedInstanceId" -}}
{{- end -}}
{{- end -}}
{{- end -}}
