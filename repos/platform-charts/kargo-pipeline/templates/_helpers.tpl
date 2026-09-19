{{/* Project (and namespace) name: <kind>-<name>. Every template includes it, so kind/name are validated once here. */}}
{{- define "kargo-pipeline.project" -}}
{{- if not (has .Values.kind (list "addon")) }}
{{- fail (printf "kind %q is not supported (addon; app lands in Phase 3)" .Values.kind) }}
{{- end }}
{{- printf "%s-%s" .Values.kind (required "name is required" .Values.name) }}
{{- end }}

{{/* chart/namespace/releaseName fall back to name: the common case is one name for all of them. */}}
{{- define "kargo-pipeline.chart" -}}{{ .Values.chart | default .Values.name }}{{- end }}
{{- define "kargo-pipeline.namespace" -}}{{ .Values.namespace | default .Values.name }}{{- end }}
{{- define "kargo-pipeline.releaseName" -}}{{ .Values.releaseName | default .Values.name }}{{- end }}

{{/* Ring whose clusters a stage (dict name/env) serves: same rule as the worker-addons appset, where a cluster with
     ring canary follows rendered/<env>-canary and every other cluster rendered/<env>. */}}
{{- define "kargo-pipeline.ring" -}}{{ if eq .name (printf "%s-canary" .env) }}canary{{ else }}stable{{ end }}{{- end }}

{{/* Kind-specific vars for the render-<kind> ClusterPromotionTask (names must match its spec.vars: contract test). */}}
{{- define "kargo-pipeline.vars.addon" -}}
- { name: addon, value: {{ .Values.name | quote }} }
- { name: chart, value: {{ include "kargo-pipeline.chart" . | quote }} }
- { name: namespace, value: {{ include "kargo-pipeline.namespace" . | quote }} }
- { name: releaseName, value: {{ include "kargo-pipeline.releaseName" . | quote }} }
{{- end }}
