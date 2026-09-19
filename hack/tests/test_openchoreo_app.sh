#!/usr/bin/env bash
# openchoreo-app chart: one chart, four modes (types | component | release | binding); see
# docs/plans/2026-09-19-openchoreo-rendered-manifests-plan.md Task 3.1. The modes, names, hashes and rejected renders:
# its unit tests (repos/platform-charts/openchoreo-app/tests/). Here: the vendored types against the control plane that
# serves them, and a release's frozen spec against the vendored file. Schema check against the real CRDs:
# test_openchoreo_app_schema.sh; the real apps: test_app_pipeline.sh.
source "$(dirname "$0")/lib.sh"
c=$charts/openchoreo-app
a=$c/tests/values/podinfo            # the chart's unit-test app, shaped like repos/apps/<app>/
rel='select(.kind=="ComponentRelease")'

# vendored from the same tag the control plane runs (bumping openchoreo-control-plane means re-vendoring)
ver=$(yq '.dependencies[] | select(.name=="openchoreo-control-plane") | .version' $charts/openchoreo-control-plane/Chart.yaml)
for f in $c/files/types/*.yaml; do
  grep -qF "# Source: https://github.com/openchoreo/openchoreo/blob/v$ver/samples/getting-started/all.yaml" "$f" ||
    fail "$f: no source header for v$ver"
done

# frozen = the vendored ClusterComponentType spec, plus the defaults the apiserver would add (resources[].targetPlane)
r=$(render podinfo $c -f $a/app.yaml -f $a/envs/dev/values.yaml --set env=dev --set stage=dev --set mode=release --set image.tag=6.15.0)
want=$(yq -o json -I0 '.spec | sort_keys(..)' $c/files/types/clustercomponenttype-service.yaml)
assert_yq "$r" "$rel | .spec.componentType.spec | del(.resources[].targetPlane) | sort_keys(..) | to_json(0)" "$want"
