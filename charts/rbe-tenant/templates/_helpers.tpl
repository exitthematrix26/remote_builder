{{/*
Common labels applied to all resources.
*/}}
{{- define "rbe-tenant.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rbe-lab
{{- end }}

{{/*
Selector labels for bb-storage.
*/}}
{{- define "rbe-tenant.storage.selectorLabels" -}}
app.kubernetes.io/name: bb-storage
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for bb-scheduler.
*/}}
{{- define "rbe-tenant.scheduler.selectorLabels" -}}
app.kubernetes.io/name: bb-scheduler
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels for bb-worker.
*/}}
{{- define "rbe-tenant.worker.selectorLabels" -}}
app.kubernetes.io/name: bb-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
