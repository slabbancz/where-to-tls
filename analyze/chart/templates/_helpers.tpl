{{- define "analyze.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "analyze.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains (include "analyze.name" .) .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "analyze.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "analyze.labels" -}}
app.kubernetes.io/name: {{ include "analyze.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | quote }}
{{- end }}

{{- define "analyze.selectorLabels" -}}
app.kubernetes.io/name: {{ include "analyze.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "analyze.validate" -}}
{{- $resultsDir := .Values.importer.source.resultsDir -}}
{{- $artifacts := .Values.importer.source.artifacts -}}
{{- if and $resultsDir (gt (len $artifacts) 0) -}}
{{- fail "importer.source.resultsDir and importer.source.artifacts are mutually exclusive" -}}
{{- end -}}
{{- if and (not $resultsDir) (eq (len $artifacts) 0) -}}
{{- fail "configure exactly one importer source: importer.source.resultsDir or importer.source.artifacts" -}}
{{- end -}}
{{- end }}
