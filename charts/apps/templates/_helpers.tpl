{{- define "apps.routingLabels" -}}
{{- $workload := include "apps.selectedWorkload" . | fromJson -}}
wtt/scenario: {{ $workload.labels.scenario | quote }}
wtt/stack: {{ $workload.labels.stack | quote }}
wtt/tls: {{ $workload.labels.tls | quote }}
{{- end -}}

{{- define "apps.selectedWorkload" -}}
{{- $go := index .Values "workload-go" -}}
{{- $net := index .Values "workload-net" -}}
{{- $java := index .Values "workload-java" -}}
{{- $rust := index .Values "workload-rust" -}}
{{- if $go.enabled -}}
{{- toJson $go -}}
{{- else if $net.enabled -}}
{{- toJson $net -}}
{{- else if $java.enabled -}}
{{- toJson $java -}}
{{- else -}}
{{- toJson $rust -}}
{{- end -}}
{{- end -}}

{{- define "apps.validate" -}}
{{- $goEnabled := (index .Values "workload-go").enabled -}}
{{- $netEnabled := (index .Values "workload-net").enabled -}}
{{- $javaEnabled := (index .Values "workload-java").enabled -}}
{{- $rustEnabled := (index .Values "workload-rust").enabled -}}
{{- if ne (add (ternary 1 0 $goEnabled) (ternary 1 0 $netEnabled) (ternary 1 0 $javaEnabled) (ternary 1 0 $rustEnabled)) 1 -}}
{{- fail "exactly one workload-<stack>.enabled value must be true" -}}
{{- end -}}
{{- $routing := .Values.routing -}}
{{- $workload := include "apps.selectedWorkload" . | fromJson -}}
{{- if or (eq $workload.labels.scenario "") (eq $workload.labels.scenario "unset") }}{{ fail "enabled workload labels.scenario is required" }}{{ end -}}
{{- if eq $routing.mode "direct" -}}
  {{- if ne $workload.service.type "LoadBalancer" }}{{ fail "direct routing requires a LoadBalancer workload Service" }}{{ end -}}
  {{- if ne $routing.gatewayClass "" }}{{ fail "direct routing must not set routing.gatewayClass" }}{{ end -}}
  {{- if ne $routing.certificateSecretName "" }}{{ fail "direct routing must not set routing.certificateSecretName" }}{{ end -}}
  {{- if $workload.config.tls.enabled -}}
    {{- if ne $workload.labels.tls "pod" }}{{ fail "direct TLS requires wtt/tls: pod" }}{{ end -}}
  {{- else if ne $workload.labels.tls "none" }}{{ fail "direct plaintext requires wtt/tls: none" }}{{ end -}}
{{- else if eq $routing.mode "passthrough" -}}
  {{- if ne $workload.service.type "ClusterIP" }}{{ fail "passthrough routing requires a ClusterIP workload Service" }}{{ end -}}
  {{- if not $workload.config.tls.enabled }}{{ fail "passthrough routing requires pod TLS" }}{{ end -}}
  {{- if ne $workload.labels.tls "pod" }}{{ fail "passthrough routing requires wtt/tls: pod" }}{{ end -}}
  {{- if ne (int $routing.backendPort) 8443 }}{{ fail "passthrough routing requires backendPort: 8443" }}{{ end -}}
  {{- if ne $routing.certificateSecretName "" }}{{ fail "passthrough routing must not set routing.certificateSecretName" }}{{ end -}}
{{- else if eq $routing.mode "terminate" -}}
  {{- if ne $workload.service.type "ClusterIP" }}{{ fail "terminating routing requires a ClusterIP workload Service" }}{{ end -}}
  {{- if ne $workload.labels.tls "traefik" }}{{ fail "terminating routing requires wtt/tls: traefik" }}{{ end -}}
  {{- if eq $routing.certificateSecretName "" }}{{ fail "terminating routing requires routing.certificateSecretName" }}{{ end -}}
  {{- if $routing.backendTLS.enabled -}}
    {{- if not $workload.config.tls.enabled }}{{ fail "terminating backend TLS requires pod TLS" }}{{ end -}}
    {{- if ne (int $routing.backendPort) 8443 }}{{ fail "terminating backend TLS requires backendPort: 8443" }}{{ end -}}
    {{- if eq $routing.backendTLS.caConfigMapName "" }}{{ fail "terminating backend TLS requires routing.backendTLS.caConfigMapName" }}{{ end -}}
  {{- else -}}
    {{- if $workload.config.tls.enabled }}{{ fail "plaintext terminating backend requires pod TLS disabled" }}{{ end -}}
    {{- if ne (int $routing.backendPort) 8080 }}{{ fail "plaintext terminating backend requires backendPort: 8080" }}{{ end -}}
  {{- end -}}
{{- else -}}
{{- fail "routing.mode must be direct, passthrough, or terminate" -}}
{{- end -}}
{{- end -}}
