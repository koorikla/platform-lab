{{/* The cluster's identity: required, a DNS-1123 label (auth mount k8s-<name>, OpenBao path, agent client-cert CN) */}}
{{- define "birth-kit.clusterName" -}}
{{- $n := required "clusterName is required (CAAPH valuesTemplate: clusterName: {{ .Cluster.metadata.name }})" .Values.clusterName | toString -}}
{{- if or (gt (len $n) 63) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $n)) -}}
{{- fail (printf "clusterName %q is not a DNS-1123 label" $n) -}}
{{- end -}}
{{- $n -}}
{{- end }}

{{- define "birth-kit.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{/* ESO's namespace and ServiceAccount, from the subchart's values (one source for the store and the binding) */}}
{{- define "birth-kit.esoNamespace" -}}
{{- required "external-secrets.namespaceOverride is required (OpenBao role eso binds external-secrets/external-secrets)" (index .Values "external-secrets").namespaceOverride -}}
{{- end }}
{{- define "birth-kit.esoServiceAccount" -}}
{{- required "external-secrets.fullnameOverride is required (it names ESO's ServiceAccount)" (index .Values "external-secrets").fullnameOverride -}}
{{- end }}
