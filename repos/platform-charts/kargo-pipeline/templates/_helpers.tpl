{{/* Kargo Project (and its namespace) for this pipeline: addon-<name> / app-<name>. */}}
{{- define "kargo-pipeline.project" -}}
{{ printf "%s-%s" .Values.kind (required "name is required" .Values.name) }}
{{- end }}

{{/* chart/namespace/releaseName fall back to name: the common case is one name for all of them. */}}
{{- define "kargo-pipeline.chart" -}}{{ .Values.chart | default .Values.name }}{{- end }}
{{- define "kargo-pipeline.namespace" -}}{{ .Values.namespace | default .Values.name }}{{- end }}
{{- define "kargo-pipeline.releaseName" -}}{{ .Values.releaseName | default .Values.name }}{{- end }}
