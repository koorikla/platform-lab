{{/* Chart name, truncated to the 63 chars Kubernetes allows in names and label values. */}}
{{- define "${{ values.name }}.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* <release>-<chart>, or just <release> when it already contains the chart name. */}}
{{- define "${{ values.name }}.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "${{ values.name }}.selectorLabels" -}}
app.kubernetes.io/name: {{ include "${{ values.name }}.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "${{ values.name }}.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "${{ values.name }}.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
