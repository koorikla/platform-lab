#!/usr/bin/env bash
# Offline sanity check: build deps, lint every chart, render each addon/cluster with the values GitOps would pass.
set -euo pipefail
cd "$(dirname "$0")/.."
charts=repos/platform-charts
config=repos/platform-config

# helm only resolves https (non-OCI) dependency repos that are registered locally
grep -ho 'repository: https://[^ ]*' $charts/*/Chart.yaml repos/apps/*/chart/Chart.yaml | sort -u | awk '{print $2}' |
  while read -r url; do helm repo add "$(echo "$url" | md5 -q 2>/dev/null || echo "$url" | md5sum | cut -c1-32)" "$url" --force-update >/dev/null; done

for c in $charts/*/ repos/apps/*/chart/; do
  helm dependency update "$c" >/dev/null
  helm lint --quiet "$c" --set name=lint,env=dev
done

render() { helm template "$@" >/dev/null || { echo "FAIL: helm template $*"; exit 1; }; }

# addons: chart defaults < scope values (< env/cluster values for workers)
for a in $config/addons/management/*/; do
  chart=$(awk '/chart:/ {print $2}' "$a"/addon.yaml*); render "$chart" "$charts/$chart" -f "$a/values.yaml"
done
for a in $config/addons/workers/*/; do
  chart=$(awk '/chart:/ {print $2}' "$a"/addon.yaml*)
  for env in dev test prod; do
    f=(-f "$a/values.yaml"); [ -f "$a/envs/$env.values.yaml" ] && f+=(-f "$a/envs/$env.values.yaml")
    render "$chart" "$charts/$chart" "${f[@]}"
  done
done
# appsets take the addon name from the folder (Kargo project, rendered/<stage>/addons/<name>); addon.yaml must agree
for f in $config/addons/*/*/addon.yaml*; do
  [ "$(awk '/name:/ {print $2; exit}' "$f")" = "$(basename "$(dirname "$f")")" ] || { echo "FAIL: $f: addon.name != folder"; exit 1; }
done
# render-addon renders for the fleet's Kubernetes minor (charts gate on .Capabilities.KubeVersion)
kv=$(awk -F'"' '/kubeVersion:/ {print $2}' $config/kargo/shared/render-addon.yaml | cut -d. -f1,2)
for f in $config/fleet/clusters/*/*.yaml*; do
  fv=$(awk '/^kubernetesVersion:/ {print $2}' "$f" | sed 's/^v//' | cut -d. -f1,2)
  [ "$fv" = "$kv" ] || { echo "FAIL: $f: kubernetesVersion $fv != render-addon kubeVersion $kv"; exit 1; }
done
# one render per cluster file, enabled or not
for f in $config/fleet/clusters/*/*.yaml*; do render cluster $charts/cluster -f "$f"; done
echo "lint: OK"
