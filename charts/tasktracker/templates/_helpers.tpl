{{/*
charts/tasktracker/templates/_helpers.tpl
Assignment: DSO202 A4 (GitOps delivery of the Task Tracker with Argo CD)
Descriptor: 3.2 (Helm named templates), adjusted in A4 Task 1
Purpose: names, labels and image references shared by every template.
Files starting with "_" never render objects.
*/}}

{{/* tasktracker.name: chart name or nameOverride. */}}
{{- define "tasktracker.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
tasktracker.fullname: base name of every object. Release "tasktracker" gives
"tasktracker", so Services are tasktracker-db, tasktracker-backend and
tasktracker-frontend in both namespaces.
*/}}
{{- define "tasktracker.fullname" -}}
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

{{- define "tasktracker.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Environment name; rendering stops if the environment file is missing. */}}
{{- define "tasktracker.environment" -}}
{{- required "environment must be set (use -f environments/<env>/values.yaml)" .Values.environment }}
{{- end }}

{{/* C3: name of the existing credentials Secret. Required, never rendered. */}}
{{- define "tasktracker.secretName" -}}
{{- required "existingSecret must be set; the chart never renders a Secret (C3)" .Values.existingSecret }}
{{- end }}

{{/* Object names per tier. Used by the objects AND the ConfigMap/smoke test. */}}
{{- define "tasktracker.dbName" -}}
{{- printf "%s-db" (include "tasktracker.fullname" .) }}
{{- end }}
{{- define "tasktracker.backendName" -}}
{{- printf "%s-backend" (include "tasktracker.fullname" .) }}
{{- end }}
{{- define "tasktracker.frontendName" -}}
{{- printf "%s-frontend" (include "tasktracker.fullname" .) }}
{{- end }}
{{- define "tasktracker.configName" -}}
{{- printf "%s-config" (include "tasktracker.fullname" .) }}
{{- end }}

{{/*
C1: "<repository>:<tag>", both from values. No tag is written in a template
and there is no fallback to appVersion, so a missing tag fails the render.
Call with (dict "image" .Values.<tier>.image "tier" "<tier>").
*/}}
{{- define "tasktracker.image" -}}
{{- $tag := required (printf "%s.image.tag must be set in the environment values file (C1)" .tier) .image.tag }}
{{- printf "%s:%s" .image.repository (toString $tag) }}
{{- end }}

{{/*
C2: render a values map as plain env entries, sorted for stable output.
Call with a map, e.g. (include "tasktracker.extraEnv" .Values.backend.env).
*/}}
{{- define "tasktracker.extraEnv" -}}
{{- range $k, $v := . }}
- name: {{ $k }}
  value: {{ $v | toString | quote }}
{{- end }}
{{- end }}

{{/* Stable selector labels. Called with (dict "ctx" $ "tier" "<tier>"). */}}
{{- define "tasktracker.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tasktracker.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
tier: {{ .tier }}
{{- end }}

{{/* Full label set for an object of one tier. */}}
{{- define "tasktracker.labels" -}}
helm.sh/chart: {{ include "tasktracker.chart" .ctx }}
{{ include "tasktracker.selectorLabels" . }}
app.kubernetes.io/component: {{ .tier }}
app.kubernetes.io/part-of: tasktracker
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/environment: {{ include "tasktracker.environment" .ctx | quote }}
{{- end }}

{{/* Labels for objects that belong to no single tier. */}}
{{- define "tasktracker.commonLabels" -}}
helm.sh/chart: {{ include "tasktracker.chart" . }}
app.kubernetes.io/name: {{ include "tasktracker.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: tasktracker
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/environment: {{ include "tasktracker.environment" . | quote }}
{{- end }}
