{{- define "workload.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "workload.labels" -}}
app.kubernetes.io/name: workload
app.kubernetes.io/instance: {{ .Release.Name }}
wtt/scenario: {{ .Values.labels.scenario | quote }}
wtt/stack: {{ .Values.labels.stack | quote }}
wtt/tls: {{ .Values.labels.tls | quote }}
{{- end -}}

{{- define "workload.selectorLabels" -}}
app.kubernetes.io/name: workload
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "workload.validate" -}}
{{- if and .Values.config.tls.enabled (ne .Values.labels.tls "pod") (ne .Values.labels.tls "traefik") }}{{ fail "TLS workload requires labels.tls: pod or traefik" }}{{ end -}}
{{- if and (not .Values.config.tls.enabled) (or (eq .Values.labels.tls "pod") (eq .Values.labels.tls "traefik")) }}{{ fail "plaintext workload cannot use labels.tls: pod or traefik" }}{{ end -}}
{{- if eq .Values.global.image.tag "latest" }}{{ fail "global.image.tag cannot be latest" }}{{ end -}}
{{- if eq .Values.global.image.registry "" }}{{ fail "global.image.registry is required" }}{{ end -}}
{{- if eq .Values.global.image.tag "" }}{{ fail "global.image.tag is required" }}{{ end -}}
{{- if and .Values.config.tls.enabled (eq .Values.tls.secretName "") }}{{ fail "TLS workloads require tls.secretName" }}{{ end -}}
{{- end -}}
