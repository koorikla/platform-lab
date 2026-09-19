#!/usr/bin/env bash
# Gateway API v1.5.1 standard-channel CRDs (hub + workers) via Envoy's gateway-crds-helm, Envoy's own CRDs off
source "$(dirname "$0")/lib.sh"
std='gateway.networking.k8s.io/'
want='backendtlspolicies,gatewayclasses,gateways,grpcroutes,httproutes,listenersets,referencegrants,tlsroutes'
check() {   # check <render>: the full standard-channel bundle at v1.5.1 and nothing else
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition") | .spec.names.plural] | sort | join(",")' "$want"
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition") | .spec.group] | unique | join(",")' gateway.networking.k8s.io
  assert_yq "$1" "[select(.kind==\"CustomResourceDefinition\") | .metadata.annotations[\"${std}bundle-version\"]] | unique | join(\",\")" v1.5.1
  assert_yq "$1" "[select(.kind==\"CustomResourceDefinition\") | .metadata.annotations[\"${std}channel\"]] | unique | join(\",\")" standard
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition" and (.spec.group | test("envoyproxy")))] | length' 0
  # upstream's upgrade guard (blocks e.g. an older bundle over a newer one) ships with the CRDs
  assert_yq "$1" '[select(.kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding") | .metadata.name] | unique | join(",")' \
    safe-upgrades.gateway.networking.k8s.io
  # nothing namespaced: the addon namespace (kube-system) only hosts the Argo/Kargo release, no objects
  assert_yq "$1" '[select(.metadata.namespace != null)] | length' 0
}
# hub: exactly what the mgmt-gateway-api-crds Application renders
m=$(render gateway-api-crds $charts/gateway-api-crds -n kube-system -f $config/addons/management/gateway-api-crds/values.yaml)
check "$m"
for c in gateways httproutes gatewayclasses referencegrants grpcroutes; do
  assert_yq "$m" "[select(.kind==\"CustomResourceDefinition\") | .metadata.name] | contains([\"$c.gateway.networking.k8s.io\"])" true
done
# CRDs are chart templates (not crds/): a render WITHOUT --include-crds has them, so helm/Argo/Kargo upgrade them
assert_yq "$m" '[select(.kind=="CustomResourceDefinition")] | length' 8
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
