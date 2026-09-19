#!/usr/bin/env bash
# Gateway API v1.5.1 standard-channel CRDs (hub + workers) via Envoy's gateway-crds-helm, Envoy's own CRDs off.
# The chart's content: its unit tests (repos/platform-charts/gateway-api-crds/tests/). Here: the hub and every worker
# env overlay, rendered the way Argo CD / Kargo's render-addon do, still yield exactly that bundle, in kube-system.
source "$(dirname "$0")/lib.sh"
std='gateway.networking.k8s.io/'
want='backendtlspolicies,gatewayclasses,gateways,grpcroutes,httproutes,listenersets,referencegrants,tlsroutes'
check() {   # check <render>: the standard-channel bundle at v1.5.1
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition") | .spec.names.plural] | sort | join(",")' "$want"
  assert_yq "$1" "[select(.kind==\"CustomResourceDefinition\") | .metadata.annotations[\"${std}bundle-version\"]] | unique | join(\",\")" v1.5.1
  assert_yq "$1" "[select(.kind==\"CustomResourceDefinition\") | .metadata.annotations[\"${std}channel\"]] | unique | join(\",\")" standard
}
# hub: exactly what the mgmt-gateway-api-crds Application renders
m=$(render gateway-api-crds $charts/gateway-api-crds -n kube-system -f $config/addons/management/gateway-api-crds/values.yaml)
check "$m"
# workers: every env overlay, rendered like Kargo's render-addon (includeCRDs, skipTests)
for env in dev test prod; do
  a=$config/addons/workers/gateway-api-crds; f=(-f "$a/values.yaml")
  [ ! -f "$a/envs/$env.values.yaml" ] || f+=(-f "$a/envs/$env.values.yaml")
  w=$(render gateway-api-crds $charts/gateway-api-crds -n kube-system --include-crds --skip-tests "${f[@]}")
  check "$w"
done
for s in management workers; do
  assert_yq $config/addons/$s/gateway-api-crds/addon.yaml '.addon.namespace' kube-system
done
