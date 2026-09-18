{{- define "cluster.labels" -}}
platform.lab/name: {{ required "name is required" .Values.name }}
platform.lab/env: {{ required "env is required" .Values.env }}
platform.lab/role: {{ .Values.role }}
platform.lab/provider: {{ .Values.provider }}
platform.lab/region: {{ .Values.region }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}
