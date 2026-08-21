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
*/}}
{{- define "agledger.licenseVolumeMount" -}}
{{- if .Values.license.keyFile.enabled }}
- name: license
  mountPath: {{ .Values.license.keyFile.mountPath | quote }}
  subPath: {{ .Values.license.keyFile.secretKey | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{/*
License file volume (use inside pod.volumes).
*/}}
{{- define "agledger.licenseVolume" -}}
{{- if .Values.license.keyFile.enabled }}
- name: license
  secret:
    secretName: {{ .Values.license.keyFile.secretName | quote }}
    defaultMode: 292  # 0444
{{- end }}
{{- end }}

{{/*
Node 24 Permission Model argv prefix. Emits a comma-terminated list of quoted
node argv entries (`"--permission", "--allow-fs-read=*", ...`) to prepend before
the entry script in a container command/args array. Empty when
`permission.enabled` is false. `permission.extraAllowArgs` widens the sandbox
(e.g. `--allow-fs-write=/var/log/agledger` for the file SIEM sink).
*/}}
{{- define "agledger.permissionArgs" -}}
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
got &value.valueUnstructured" (api#1018). Quoting here means `--set` works
without `--set-string`.

`value` and `valueFrom` are branched, never both emitted: an empty `value`
alongside a `valueFrom` is rejected as "may not have more than one field
specified". EnvVar carries exactly name/value/valueFrom, so this covers the type.
*/}}
{{- define "agledger.envList" -}}
{{- range . }}
- name: {{ .name | quote }}
  {{- if hasKey . "value" }}
  value: {{ .value | quote }}
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
True (non-empty) when the chart's own Secret carries DATABASE_URL.
*/}}
{{- define "agledger.chartSuppliesDatabaseUrl" -}}
{{- if not .Values.secrets.existingSecret }}
{{- if or .Values.database.externalUrl .Values.postgres.bundled.enabled }}true{{ end }}
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
{{- if .Values.provisioning.enabled }}
{{- /* Keep in sync with provisioningVolumes and provisioning-configmap.yaml */ -}}
{{- $subdirs := list "orgs" "agents" "webhooks" "schemas" }}
{{- range $subdir := $subdirs }}
- name: provisioning-{{ $subdir }}
  mountPath: {{ $.Values.provisioning.configPath }}/{{ $subdir }}
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
{{- if .Values.provisioning.enabled }}
{{- $chartCM := include "agledger.provisioningConfigMapName" . }}
{{- /* Keep in sync with provisioningVolumeMounts and provisioning-configmap.yaml */ -}}
{{- $subdirs := list "orgs" "agents" "webhooks" "schemas" }}
{{- range $subdir := $subdirs }}
{{- $existingCM := index $.Values.provisioning.existingConfigMaps $subdir }}
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
{{- end }}
{{- end }}
