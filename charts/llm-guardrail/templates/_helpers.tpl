{{/* Resource names: <release>-gateway and <release>-mock-llm. */}}
{{- define "llm-guardrail.gatewayName" -}}
{{- printf "%s-gateway" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "llm-guardrail.mockName" -}}
{{- printf "%s-mock-llm" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Full image reference, honouring global.imageRegistry for private/air-gapped registries. */}}
{{- define "llm-guardrail.image" -}}
{{- $root := index . 0 -}}
{{- $img := index . 1 -}}
{{- if $root.Values.global.imageRegistry -}}
{{- printf "%s/%s:%s" (trimSuffix "/" $root.Values.global.imageRegistry) $img.repository $img.tag -}}
{{- else -}}
{{- printf "%s:%s" $img.repository $img.tag -}}
{{- end -}}
{{- end -}}

{{- define "llm-guardrail.labels" -}}
app.kubernetes.io/part-of: llm-guardrail
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Labels for a gateway object: common labels plus the component name (the instance label is already in common). */}}
{{- define "llm-guardrail.gatewayLabels" -}}
{{ include "llm-guardrail.labels" . }}
app.kubernetes.io/name: gateway
{{- end -}}

{{- define "llm-guardrail.mockLabels" -}}
{{ include "llm-guardrail.labels" . }}
app.kubernetes.io/name: mock-llm
{{- end -}}

{{/* Pod selector. Never use together with "labels": both carry the instance label and a duplicate key is invalid YAML. */}}
{{- define "llm-guardrail.gatewaySelector" -}}
app.kubernetes.io/name: gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "llm-guardrail.mockSelector" -}}
app.kubernetes.io/name: mock-llm
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Secret that holds the LLM API key: the user's existing one, or the one we create. */}}
{{- define "llm-guardrail.secretName" -}}
{{- default (printf "%s-llm-key" .Release.Name) .Values.gateway.secret.existingSecret -}}
{{- end -}}

{{/* Upstream URL: explicit value, else mock-llm Service, else the Anthropic API. */}}
{{- define "llm-guardrail.upstreamUrl" -}}
{{- if .Values.gateway.upstream.url -}}
{{- .Values.gateway.upstream.url -}}
{{- else if eq .Values.gateway.upstream.kind "anthropic" -}}
https://api.anthropic.com
{{- else -}}
{{- printf "http://%s:8080" (include "llm-guardrail.mockName" .) -}}
{{- end -}}
{{- end -}}

{{/* imagePullSecrets block for private registries. */}}
{{- define "llm-guardrail.pullSecrets" -}}
{{- with .Values.global.imagePullSecrets }}
imagePullSecrets:
  {{- range . }}
  - name: {{ . }}
  {{- end }}
{{- end }}
{{- end -}}

{{/* DNS egress peer, configurable for clusters whose DNS is not kube-system/kube-dns (e.g. node-local-dns). */}}
{{- define "llm-guardrail.dnsEgress" -}}
- to:
    - namespaceSelector:
        matchLabels:
          {{- toYaml .Values.networkPolicy.dns.namespaceLabels | nindent 10 }}
      podSelector:
        matchLabels:
          {{- toYaml .Values.networkPolicy.dns.podLabels | nindent 10 }}
    {{- range .Values.networkPolicy.dns.extraCidrs }}
    - ipBlock:
        cidr: {{ . | quote }}
    {{- end }}
  ports:
    - { protocol: UDP, port: 53 }
    - { protocol: TCP, port: 53 }
{{- end -}}

{{/* Shared hardened container security context. */}}
{{- define "llm-guardrail.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
runAsUser: 10001
capabilities:
  drop: ["ALL"]
{{- end -}}
