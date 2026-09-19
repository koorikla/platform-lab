{{/* include "oc.required" (list $ "key" ...): fail unless every top-level value is set */}}
{{- define "oc.required" -}}
{{- $v := (first .).Values -}}
{{- range rest . }}{{ if not (index $v .) }}{{ fail (printf "openchoreo-app (mode %s): %s is required" $v.mode .) }}{{ end }}{{ end -}}
{{- end }}

{{- define "oc.stage" -}}{{ .Values.stage | default .Values.env }}{{- end }}

{{/* Frozen spec (JSON) of the ClusterComponentType named by .Values.componentType ("<workloadType>/<name>"),
     read from the same files/types the types mode applies. */}}
{{- define "oc.componentTypeSpec" -}}
{{- $parts := splitList "/" .Values.componentType -}}
{{- if ne (len $parts) 2 }}{{ fail (printf "componentType %q: want <workloadType>/<name>, e.g. deployment/service" .Values.componentType) }}{{ end -}}
{{- $found := dict -}}
{{- range $f, $_ := .Files.Glob "files/types/*.yaml" }}
{{- $d := $.Files.Get $f | fromYaml }}
{{- if and (eq $d.kind "ClusterComponentType") (eq $d.metadata.name (index $parts 1)) (eq $d.spec.workloadType (index $parts 0)) }}
{{- $_ := set $found "spec" (deepCopy $d.spec) }}
{{- end }}
{{- end -}}
{{- if not $found.spec }}{{ fail (printf "componentType %q: no such ClusterComponentType in files/types" .Values.componentType) }}{{ end -}}
{{- /* CRD schema defaults the apiserver adds on admission (resources[].targetPlane, postRenderValidations[]): applied
       here so the rendered release equals both the stored object and what the controller would freeze */ -}}
{{- range $found.spec.resources }}{{ if not (hasKey . "targetPlane") }}{{ $_ := set . "targetPlane" "dataplane" }}{{ end }}{{ end -}}
{{- range ($found.spec.postRenderValidations | default list) }}
{{- if not (hasKey . "targetPlane") }}{{ $_ := set . "targetPlane" "dataplane" }}{{ end }}
{{- if and .target (not (hasKey .target "mustMatch")) }}{{ $_ := set .target "mustMatch" true }}{{ end }}
{{- end -}}
{{- toJson $found.spec -}}
{{- end }}

{{/* ComponentRelease spec (JSON), shaped like upstream componentrelease.BuildSpec (internal/componentrelease/builder.go):
     componentProfile only when there are parameters, traits unset (none supported yet). */}}
{{- define "oc.releaseSpec" -}}
{{- include "oc.required" (list . "name" "project" "env") -}}
{{- if not (and .Values.image.repository .Values.image.tag) }}{{ fail (printf "openchoreo-app (mode %s): image.repository and image.tag are required" .Values.mode) }}{{ end -}}
{{- if .Values.traits }}{{ fail "openchoreo-app: traits are not supported yet (vendor the ClusterTrait specs to freeze them first)" }}{{ end -}}
{{- if hasKey .Values.container "image" }}{{ fail "openchoreo-app: set image.repository/image.tag, not container.image" }}{{ end -}}
{{- $container := merge (dict "image" (printf "%s:%s" .Values.image.repository (toString .Values.image.tag))) (deepCopy .Values.container) -}}
{{- $workload := dict "container" $container -}}
{{- with .Values.endpoints }}{{ $_ := set $workload "endpoints" . }}{{ end -}}
{{- with .Values.dependencies }}{{ $_ := set $workload "dependencies" . }}{{ end -}}
{{- $spec := dict
      "owner" (dict "projectName" .Values.project "componentName" .Values.name)
      "componentType" (dict "kind" "ClusterComponentType" "name" .Values.componentType "spec" (include "oc.componentTypeSpec" . | fromJson))
      "workload" $workload -}}
{{- with .Values.parameters }}{{ $_ := set $spec "componentProfile" (dict "parameters" .) }}{{ end -}}
{{- toJson $spec -}}
{{- end }}

{{/* <name>-<stage>-<tag>-<hash8>: stage keeps env branches apart, tag is for humans, the hash covers the whole spec
     (toJson sorts map keys, so it is stable). Unlike upstream's ComputeReleaseHash it includes owner: owner is
     immutable too, so a changed project must mean a new object. */}}
{{- define "oc.releaseName" -}}
{{- $tag := regexReplaceAll "[^a-z0-9-]+" (.Values.image.tag | toString | lower) "-" | trimAll "-" -}}
{{- printf "%s-%s-%s-%s" .Values.name (include "oc.stage" .) $tag (include "oc.releaseSpec" . | sha256sum | trunc 8) -}}
{{- end }}

{{- define "oc.labels" -}}
platform.lab/app: {{ .Values.name }}
{{- with (include "oc.stage" .) }}
platform.lab/stage: {{ . }}
{{- end }}
{{- end }}
