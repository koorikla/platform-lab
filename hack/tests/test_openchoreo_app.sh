#!/usr/bin/env bash
# openchoreo-app chart: one chart, four modes (types | component | release | binding). See
# docs/plans/2026-09-19-openchoreo-rendered-manifests-plan.md Task 3.1. Schema check against the real CRDs:
# test_openchoreo_app_schema.sh.
source "$(dirname "$0")/lib.sh"
c=$charts/openchoreo-app
a=hack/tests/fixtures/podinfo          # shaped like repos/apps/<app>/ (real apps: test_app_pipeline.sh)
rel='select(.kind=="ComponentRelease")'
dev=(-f "$a/app.yaml" -f "$a/envs/dev/values.yaml" --set env=dev --set stage=dev)   # what Kargo passes

# --- types (hub addon): upstream v1.2.5 getting-started types, vendored verbatim
t=$(render types $c --set mode=types)
assert_yq "$t" '[select(.kind=="ClusterComponentType") | .spec.workloadType + "/" + .metadata.name] | sort | join(",")' \
  'cronjob/scheduled-task,deployment/service,deployment/web-application,deployment/worker'
assert_yq "$t" '[select(.kind=="ClusterProjectType")] | map(.metadata.name) | join(",")' default
assert_yq "$t" '[select(.kind != null and .kind != "ClusterComponentType" and .kind != "ClusterProjectType")] | length' 0
# vendored from the same tag the control plane runs (bumping openchoreo-control-plane means re-vendoring)
ver=$(yq '.dependencies[] | select(.name=="openchoreo-control-plane") | .version' $charts/openchoreo-control-plane/Chart.yaml)
for f in $c/files/types/*.yaml; do
  grep -qF "# Source: https://github.com/openchoreo/openchoreo/blob/v$ver/samples/getting-started/all.yaml" "$f" ||
    fail "$f: no source header for v$ver"
done
# the frozen spec equals what the apiserver stores only if refs carry an explicit kind (CRD defaults would differ)
assert_yq "$t" '[select(.kind=="ClusterComponentType") | ((.spec.allowedTraits // []) + (.spec.allowedWorkflows // [])
  + (.spec.traits // []))[] | select(has("kind") | not)] | length' 0

# --- component (hub, from main): Component only; releases are cut by Kargo, not by the controller
o=$(render podinfo $c -f $a/app.yaml --set mode=component)
assert_yq "$o" '[select(.kind != null)] | map(.kind) | join(",")' Component
assert_yq "$o" 'select(.kind=="Component") | .metadata.name + "/" + .metadata.namespace' podinfo/default
assert_yq "$o" 'select(.kind=="Component") | .spec.autoDeploy' false
assert_yq "$o" 'select(.kind=="Component") | .spec.owner.projectName' lab
assert_yq "$o" 'select(.kind=="Component") | .spec.componentType.kind + ":" + .spec.componentType.name' \
  ClusterComponentType:deployment/service
o=$(render podinfo $c -f $a/app.yaml --set mode=component --set createProject=true)
assert_yq "$o" 'select(.kind=="Project") | .metadata.name' lab
assert_yq "$o" 'select(.kind=="Project") | .spec.deploymentPipelineRef.name' default
assert_yq "$o" 'select(.kind=="Project") | .spec.type.kind + ":" + .spec.type.name' ClusterProjectType:default

# --- release (Kargo): ComponentRelease <app>-<stage>-<tag>-<hash8>, frozen type spec + workload
r=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=6.15.0)
name=$(yq "$rel | .metadata.name" "$r")
[[ "$name" =~ ^podinfo-dev-6-15-0-[0-9a-f]{8}$ ]] || fail "release name $name"
# golden name: the hash must not drift between Helm versions (tests run Helm 4, Kargo embeds Helm 3) or refactors.
# Update only on an intentional change of the frozen spec (it re-cuts every release on the next promotion).
[ "$name" = podinfo-dev-6-15-0-ee034475 ] || fail "release name $name != golden (intended? update the test)"
assert_yq "$r" "$rel | .metadata.namespace" default
assert_yq "$r" "$rel | .metadata.labels[\"openchoreo.dev/project\"] + \"/\" + .metadata.labels[\"openchoreo.dev/component\"]" lab/podinfo
assert_yq "$r" "$rel | .spec.owner.projectName + \"/\" + .spec.owner.componentName" lab/podinfo
assert_yq "$r" "$rel | .spec.componentType.kind" ClusterComponentType
assert_yq "$r" "$rel | .spec.componentType.name" deployment/service
assert_yq "$r" "$rel | .spec.workload.container.image" ghcr.io/stefanprodan/podinfo:6.15.0
assert_yq "$r" "$rel | .spec.workload.container.env[0].value" 'podinfo @ dev'
assert_yq "$r" "$rel | .spec.workload.endpoints.http.port" 9898
assert_yq "$r" "$rel | .spec.workload.endpoints.http.visibility | join(\",\")" external
# frozen = the vendored ClusterComponentType spec, plus the defaults the apiserver would add (resources[].targetPlane)
assert_yq "$r" "$rel | [.spec.componentType.spec.resources[].targetPlane] | unique | join(\",\")" dataplane
want=$(yq -o json -I0 '.spec | sort_keys(..)' $c/files/types/clustercomponenttype-service.yaml)
assert_yq "$r" "$rel | .spec.componentType.spec | del(.resources[].targetPlane) | sort_keys(..) | to_json(0)" "$want"
# no parameters/traits -> upstream BuildSpec leaves componentProfile and traits unset
assert_yq "$r" "$rel | .spec | keys | sort | join(\",\")" componentType,owner,workload
# Workload (what the OpenChoreo UI shows as "latest") exists once: only the dev stage renders it
assert_yq "$r" 'select(.kind=="Workload") | .metadata.name' podinfo-workload
assert_yq "$r" 'select(.kind=="Workload") | .metadata.labels["openchoreo.dev/component"]' podinfo
assert_yq "$r" 'select(.kind=="Workload") | .spec.owner.projectName + "/" + .spec.owner.componentName' lab/podinfo
assert_yq "$r" 'select(.kind=="Workload") | .spec.container.image' ghcr.io/stefanprodan/podinfo:6.15.0
# deterministic: same inputs, same name
r1=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=6.15.0)
[ "$(yq "$rel | .metadata.name" "$r1")" = "$name" ] || fail "release name not deterministic"
# anything frozen changes the name: tag, env config, parameters
r2=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=6.16.0)
[ "$(yq "$rel | .metadata.name" "$r2")" != "$name" ] || fail "tag change must change release name"
r3=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=6.15.0 --set 'container.env[0].key=X' --set 'container.env[0].value=y')
n3=$(yq "$rel | .metadata.name" "$r3")
[[ "$n3" =~ ^podinfo-dev-6-15-0- && "$n3" != "$name" ]] || fail "config change must change the hash: $n3"
r4=$(render podinfo $c -f $a/app.yaml -f $a/envs/test/values.yaml --set env=test --set stage=test --set mode=release --set image.tag=6.15.0)
[[ "$(yq "$rel | .metadata.name" "$r4")" =~ ^podinfo-test-6-15-0-[0-9a-f]{8}$ ]] || fail "test release name"
assert_yq "$r4" '[select(.kind=="Workload")] | length' 0
# stage (Kargo branch), not env, names the release: dev-canary renders env=dev too and must not share dev's objects
r5=$(render podinfo $c -f $a/app.yaml -f $a/envs/dev/values.yaml --set env=dev --set stage=dev-canary --set mode=release --set image.tag=6.15.0)
[[ "$(yq "$rel | .metadata.name" "$r5")" =~ ^podinfo-dev-canary-6-15-0-[0-9a-f]{8}$ ]] || fail "canary release name"
assert_yq "$r5" '[select(.kind=="Workload")] | length' 0
# parameters -> Component.spec.parameters and componentProfile.parameters (same values, same place upstream puts them)
r6=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=6.15.0 --set parameters.foo=bar)
assert_yq "$r6" "$rel | .spec.componentProfile.parameters.foo" bar
o=$(render podinfo $c -f $a/app.yaml --set mode=component --set parameters.foo=bar)
assert_yq "$o" 'select(.kind=="Component") | .spec.parameters.foo' bar
# tags are sanitised into a DNS label
r7=$(render podinfo $c "${dev[@]}" --set mode=release --set image.tag=v1.2.3_rc.1)
[[ "$(yq "$rel | .metadata.name" "$r7")" =~ ^podinfo-dev-v1-2-3-rc-1-[0-9a-f]{8}$ ]] || fail "tag sanitising"

# --- binding (hub appset, from main): identity only, every input handed over from the rendered release
bind=(--set mode=binding --set name=podinfo --set project=lab --set releaseName="$name" --set environment=dev1)
b=$(render podinfo $c "${bind[@]}")
assert_yq "$b" '[select(.kind != null)] | map(.kind) | join(",")' ReleaseBinding
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .metadata.name' podinfo-dev1
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .spec.releaseName' "$name"
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .spec.environment' dev1
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .spec.owner.projectName + "/" + .spec.owner.componentName' lab/podinfo
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .spec | keys | sort | join(",")' environment,owner,releaseName
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .metadata.labels["openchoreo.dev/environment"]' dev1
# app values don't leak in: the binding is the same with or without app.yaml/env values
b2=$(render podinfo $c "${dev[@]}" --set image.tag=9.9.9 "${bind[@]}")
[ "$(yq eval-all 'select(.kind=="ReleaseBinding") | .spec | to_json(0)' "$b2")" = \
  "$(yq eval-all 'select(.kind=="ReleaseBinding") | .spec | to_json(0)' "$b")" ] || fail "binding depends on app values"

# --- rejected renders
assert_fails helm template x $c --set mode=bogus
assert_fails helm template x $c --set mode=component                                    # no name
assert_fails helm template x $c -f $a/app.yaml --set mode=component --set componentType=deployment/nope
assert_fails helm template x $c -f $a/app.yaml --set mode=component --set componentType=service   # no workloadType
assert_fails helm template x $c -f $a/app.yaml --set mode=component --set name=Pod_Info           # not DNS-1123
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set env=dev --set image.tag=1  # no stage (no env fallback)
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set stage=Dev_Canary --set image.tag=1
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set stage=dev                  # no tag
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set stage=dev --set image.tag=1 --set image.repository=
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set stage=dev --set image.tag=1 --set container.image=x
assert_fails helm template x $c -f $a/app.yaml --set mode=release --set stage=dev --set image.tag=1 \
  --set 'traits[0].name=observability-alert-rule'                                                     # not supported yet
b=(--set mode=binding --set name=podinfo --set project=lab)
assert_fails helm template x $c "${b[@]}" --set environment=dev1                   # no releaseName: never recomputed
assert_fails helm template x $c "${dev[@]}" --set image.tag=6.15.0 "${b[@]}" --set environment=dev1
assert_fails helm template x $c "${b[@]}" --set releaseName="$name"                # no environment
assert_fails helm template x $c "${b[@]}" --set releaseName="$name" --set environment=__CLUSTER__
