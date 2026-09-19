#!/usr/bin/env bash
# #13: every worker in fleet/clusters/ is registered in OpenChoreo by the cluster chart: ClusterDataPlane + Environment
# (Backstage lists both before any agent connects), plus the agent's identity. Per-cluster CA on the hub (the
# cluster-gateway takes planeID from the URL and checks only the chain, so a shared CA would let any agent claim any
# plane); the client cert and the gateway's server CA go to OpenBao secret/clusters/<name>/* for the worker to pull
# (#14). Rendered only when the hub serves the OpenChoreo CRDs (Argo passes the cluster's API versions to helm), so the
# registration follows the openchoreo-control-plane addon being enabled (addon.yaml vs addon.yaml.disabled).
# What the cluster chart renders: its unit tests (repos/platform-charts/cluster/tests/openchoreo*_test.yaml). Here:
# the contracts with the control-plane and openbao charts, and invariant 1 for every real cluster file.
source "$(dirname "$0")/lib.sh"
oc=(--api-versions openchoreo.dev/v1alpha1/ClusterDataPlane --api-versions openchoreo.dev/v1alpha1/Environment)
cdp='select(.kind=="ClusterDataPlane")'
env='select(.kind=="Environment")'
ns=openchoreo-control-plane
o=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml "${oc[@]}")
c=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n $ns \
  -f $config/addons/management/openchoreo-control-plane/values.yaml)

# openchoreo-api (and so Backstage) lists Environments only in namespaces the control-plane umbrella labels
envNs=$(yq "$env | .metadata.namespace" "$o")
assert_yq "$c" "select(.kind==\"Namespace\" and .metadata.name==\"$envNs\") | .metadata.labels[\"openchoreo.dev/control-plane\"]" true
# the agent's CA chain lives next to the cluster-gateway that trusts it
assert_yq "$o" "[select(.kind==\"Certificate\" and .metadata.namespace != \"argocd\") | .metadata.namespace] | unique | join(\",\")" \
  "$(yq 'select(.kind=="Deployment" and .metadata.name=="cluster-gateway") | .metadata.namespace' "$c")"
# the gateway CA we push is the one that signs the cluster-gateway's server cert (the cert with dnsName mgmt-lb)
srvIssuer=$(yq 'select(.kind=="Certificate" and (.spec.dnsNames // [] | contains(["mgmt-lb"]))) | .spec.issuerRef.name' "$c")
[ -n "$srvIssuer" ] || fail "no cluster-gateway server Certificate with dnsName mgmt-lb in the control-plane render"
gca=$(yq 'select(.kind=="PushSecret" and (.metadata.name | test("-openchoreo-gateway-ca$"))) | .spec.selector.secret.name' "$o")
assert_yq "$c" "select(.kind==\"Issuer\" and .metadata.name==\"$srvIssuer\") | .spec.ca.secretName" "$gca"
# ClusterSecretStore openbao admits PushSecrets only from hubWriter.namespaces (platform-charts/openbao)
b=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
for n in $(yq eval-all '[select(.kind=="PushSecret") | .metadata.namespace] | unique | .[]' "$o"); do
  assert_yq "$b" "select(.kind==\"ClusterSecretStore\" and .metadata.name==\"openbao\") | .spec.conditions[0].namespaces | contains([\"$n\"])" true
done

# --- the hub file registers nothing (it is the control plane)
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml "${oc[@]}")
assert_yq "$h" '[select(.apiVersion | test("^openchoreo.dev/"))] | length' 0

# --- invariant 1 for every cluster file: ClusterDataPlane name == planeID == Environment name == fleet name
for f in $config/fleet/clusters/*/*.yaml*; do
  [ "$(yq '.role // "worker"' "$f")" = worker ] || continue
  n=$(yq '.name' "$f")
  r=$(render "$n" $charts/cluster -f "$f" "${oc[@]}")
  assert_yq "$r" "[$cdp | .metadata.name, .spec.planeID] + [$env | .metadata.name, .spec.dataPlaneRef.name] | unique | join(\",\")" "$n"
  # prod files make production Environments
  assert_yq "$r" "$env | .spec.isProduction" "$([ "$(yq .env "$f")" = prod ] && echo true || echo false)"
done
