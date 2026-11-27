{{/* Cross-field checks that JSON schema cannot express. Included from configmap-policy.yaml so it always runs. */}}
{{- define "llm-guardrail.validate" -}}
{{- if and (eq .Values.gateway.upstream.kind "mock") (not .Values.mockLlm.enabled) (not .Values.gateway.upstream.url) -}}
{{- fail "gateway.upstream.kind=mock with mockLlm.enabled=false has no upstream: enable mockLlm or set gateway.upstream.url" -}}
{{- end -}}
{{- if and (eq .Values.gateway.upstream.kind "anthropic") .Values.networkPolicy.enabled (not .Values.networkPolicy.externalLLM.enabled) -}}
{{- fail "gateway.upstream.kind=anthropic with networkPolicy.enabled=true needs networkPolicy.externalLLM.enabled=true and cidrs, otherwise default-deny blocks every upstream call" -}}
{{- end -}}
{{- if and .Values.ingress.enabled (not .Values.networkPolicy.allowedNamespaces) (not .Values.networkPolicy.allowedIngressCidrs) .Values.networkPolicy.enabled -}}
{{- fail "ingress.enabled=true but networkPolicy.allowedNamespaces and allowedIngressCidrs are both empty: the ingress controller could not reach the gateway" -}}
{{- end -}}
{{- end -}}
