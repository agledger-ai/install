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
*/}}
{{- define "agledger.image" -}}
{{- $tag := default .Chart.AppVersion .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository $tag }}
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
{{- $subdirs := list "enterprises" "agents" "webhooks" "schemas" }}
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
{{- $subdirs := list "enterprises" "agents" "webhooks" "schemas" }}
{{- range $subdir := $subdirs }}
{{- $existingCM := index $.Values.provisioning.existingConfigMaps $subdir }}
- name: provisioning-{{ $subdir }}
  configMap:
    {{- if $existingCM }}
    name: {{ $existingCM }}
    {{- else }}
    name: {{ $chartCM }}
    {{- end }}
    defaultMode: 292  # 0444
    optional: true
    {{- if and (not $existingCM) (index $.Values.provisioning $subdir) }}
    items:
      {{- range $key, $_ := index $.Values.provisioning $subdir }}
      - key: {{ $subdir }}--{{ $key }}
        path: {{ $key }}
      {{- end }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}
