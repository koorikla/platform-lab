#!/usr/bin/env bash
# Offline sanity check: build deps, lint every chart, render each addon/cluster with the values GitOps would pass.
set -euo pipefail
cd "$(dirname "$0")/.."
charts=repos/platform-charts
config=repos/platform-config

# helm only resolves https (non-OCI) dependency repos that are registered locally
grep -ho 'repository: https://[^ ]*' $charts/*/Chart.yaml repos/apps/*/chart/Chart.yaml | sort -u | awk '{print $2}' |
  while read -r url; do helm repo add "$(echo "$url" | md5 -q 2>/dev/null || echo "$url" | md5sum | cut -c1-32)" "$url" --force-update >/dev/null; done

# required values: name/env (cluster chart), clusterName (worker-birth-kit)
for c in $charts/*/ repos/apps/*/chart/; do
  helm dependency update "$c" >/dev/null
  helm lint --quiet "$c" --set name=lint,env=dev,clusterName=lint
done

render() { helm template "$@" >/dev/null || { echo "FAIL: helm template $*"; exit 1; }; }

# addons: chart defaults < scope values (< env values for workers, as Kargo's render-addon passes them)
for a in $config/addons/management/*/; do
  chart=$(awk '/chart:/ {print $2}' "$a"/addon.yaml*); render "$chart" "$charts/$chart" -f "$a/values.yaml"
done
# the environments are the envs of kargo-pipeline's stages (dev, nit, sit, prod): the one list, used below too
envs=$(yq '[.stages[].env] | unique | .[]' $charts/kargo-pipeline/values.yaml)
for a in $config/addons/workers/*/; do
  chart=$(awk '/chart:/ {print $2}' "$a"/addon.yaml*)
  for env in $envs; do
    f=(-f "$a/values.yaml"); [ -f "$a/envs/$env.values.yaml" ] && f+=(-f "$a/envs/$env.values.yaml")
    render "$chart" "$charts/$chart" "${f[@]}"
    # Kargo's flat layout writes one file per <group>-<kind>-<namespace>-<name>: nameless or duplicate resources
    # would silently overwrite each other on rendered/<stage> (see render-addon.yaml)
    ids=$(helm template "$chart" "$charts/$chart" -n "$chart" --include-crds --skip-tests "${f[@]}" |
      yq -N 'select(.kind != null) | .apiVersion + "/" + .kind + "/" + (.metadata.namespace // "") + "/" + (.metadata.name // "<none>")')
    ! grep -q '/<none>$' <<<"$ids" || { echo "FAIL: $chart ($env): resource without metadata.name"; exit 1; }
    [ -z "$(sort <<<"$ids" | uniq -d)" ] || { echo "FAIL: $chart ($env): duplicate resources: $(sort <<<"$ids" | uniq -d)"; exit 1; }
  done
done
# appsets take the addon name from the folder (Kargo project, rendered/<stage>/addons/<name>); addon.yaml must agree
for f in $config/addons/*/*/addon.yaml*; do
  [ "$(yq '.addon.name' "$f")" = "$(basename "$(dirname "$f")")" ] || { echo "FAIL: $f: addon.name != folder"; exit 1; }
done
# apps: the folder names the Component and the Kargo project (app-<name>); render what Kargo's render-app (release per
# env) and the hub (component) render. Flat file names, one release per stage: hack/tests/test_app_pipeline.sh
for f in repos/apps/*/app.yaml; do
  d=$(dirname "$f")
  [ "$(yq '.name' "$f")" = "$(basename "$d")" ] || { echo "FAIL: $f: name != folder"; exit 1; }
  repo=$(yq '.image.repository // ""' "$f")
  [ -n "$repo" ] || { echo "FAIL: $f: image.repository is required"; exit 1; }
  # no version on main (invariant 5): a tag or digest in the repository would pin every stage
  [[ ! ${repo##*/} =~ [:@] ]] || { echo "FAIL: $f: image.repository $repo carries a tag/digest (Kargo's Freight does)"; exit 1; }
  render "$(basename "$d")" $charts/openchoreo-app -f "$f" --set mode=component
  for e in "$d"/envs/*/; do
    render "$(basename "$d")" $charts/openchoreo-app -f "$f" -f "$e/values.yaml" --set mode=release \
      --set stage="$(basename "$e")" --set-literal image.tag=0.0.0-lint
  done
done
# render-addon renders for the fleet's Kubernetes minor (charts gate on .Capabilities.KubeVersion)
kv=$(awk -F'"' '/kubeVersion:/ {print $2}' $config/kargo/shared/render-addon.yaml | cut -d. -f1,2)
# Enabled clusters only: disabled examples (e.g. eks-dev1, whose EKS version Renovate's k3s manager doesn't bump) are
# checked when they are enabled.
for f in $config/fleet/clusters/*/*.yaml; do
  [[ $f == */clusters/mgmt/* ]] && continue   # only workers consume rendered manifests
  fv=$(awk '/^kubernetesVersion:/ {print $2}' "$f" | sed 's/^v//' | cut -d. -f1,2)
  [ "$fv" = "$kv" ] || { echo "FAIL: $f: kubernetesVersion $fv != render-addon kubeVersion $kv"; exit 1; }
done
# worker-addons points a canary cluster at rendered/<env>-canary: Kargo must render that branch (a stage of that name),
# else the Applications only show a ComparisonError at runtime
stages=" $(yq '.stages[].name' $charts/kargo-pipeline/values.yaml | paste -sd' ' -) "
# a worker's env picks rendered/<env> and the env values: an env without a stage has neither, and its Applications only
# show a ComparisonError at runtime. The file lives in clusters/<env>/ (enabled or not; the hub is env mgmt).
for f in $config/fleet/clusters/*/*.yaml*; do
  e=$(yq '.env' "$f")
  [ "$e" = "$(basename "$(dirname "$f")")" ] || { echo "FAIL: $f: env $e, but the file is in clusters/$(basename "$(dirname "$f")")/"; exit 1; }
  [ "$(yq '.role // "worker"' "$f")" = management ] && continue
  grep -qx -- "$e" <<<"$envs" || { echo "FAIL: $f: env $e is not a kargo-pipeline stage env ($(paste -sd' ' - <<<"$envs"))"; exit 1; }
done
for f in $config/fleet/clusters/*/*.yaml*; do
  [ "$(yq '.ring // "stable"' "$f")" = canary ] || continue
  s="$(yq '.env' "$f")-canary"
  [[ $stages == *" $s "* ]] || { echo "FAIL: $f: ring canary, but kargo-pipeline has no stage $s"; exit 1; }
done
# one render per cluster file, enabled or not; again as on a hub serving OpenChoreo (templates/openchoreo.yaml)
for f in $config/fleet/clusters/*/*.yaml*; do
  render cluster $charts/cluster -f "$f"
  render cluster $charts/cluster -f "$f" --api-versions openchoreo.dev/v1alpha1/ClusterDataPlane
done
echo "lint: OK"
