{{/*
Expand the name of the chart.
*/}}
{{- define "buildbarn.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "buildbarn.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rbe-lab
{{- end }}

{{/*
Selector labels for bb-storage.
*/}}
{{- define "buildbarn.storage.selectorLabels" -}}
app.kubernetes.io/name: bb-storage
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for bb-scheduler.
*/}}
{{- define "buildbarn.scheduler.selectorLabels" -}}
app.kubernetes.io/name: bb-scheduler
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for bb-worker.
*/}}
{{- define "buildbarn.worker.selectorLabels" -}}
app.kubernetes.io/name: bb-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
