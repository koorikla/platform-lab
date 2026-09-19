#!/usr/bin/env bash
# kgateway (OpenChoreo prerequisite) on the hub and on workers, at the version and in the namespaces OpenChoreo v1.2.5
# installs it (install/k3d/k3d-prerequisites.sh, install/k3d/multi-cluster/README.md at v1.2.5).
source "$(dirname "$0")/lib.sh"
want_crds='backendconfigpolicies,backends,directresponses,gatewayextensions,gatewayparameters,httplistenerpolicies,listenerpolicies,trafficpolicies'
# upstream pins both charts to the same release
assert_yq $charts/kgateway/Chart.yaml '[.dependencies[] | .name + "@" + .version] | join(",")' 'kgateway-crds@v2.3.1,kgateway@v2.3.1'

check() {   # check <render> <namespace>
  # only gateway.kgateway.dev CRDs: Gateway API CRDs belong to the gateway-api-crds addon (and its safe-upgrades VAP)
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition") | .spec.names.plural] | sort | join(",")' "$want_crds"
  assert_yq "$1" '[select(.kind=="CustomResourceDefinition") | .spec.group] | unique | join(",")' gateway.kgateway.dev
  # one controller, upstream image at the pinned tag
  assert_yq "$1" '[select(.kind=="Deployment") | .metadata.name] | join(",")' kgateway
  assert_yq "$1" 'select(.kind=="Deployment") | .spec.template.spec.containers[0].image' \
    cr.kgateway.dev/kgateway-dev/kgateway:v2.3.1
  # everything namespaced lands in the addon namespace
  assert_yq "$1" "[select(.metadata.namespace != null) | .metadata.namespace] | unique | join(\",\")" "$2"
  # GatewayClass kgateway is created by the controller at startup, not by the chart: nothing for Argo to fight over
  assert_yq "$1" '[select(.kind=="GatewayClass")] | length' 0
}

# hub: kgateway next to the OpenChoreo control plane, like upstream
m=$config/addons/management/kgateway
[ -f $m/addon.yaml ] && [ ! -e $m/addon.yaml.disabled ] || fail "hub kgateway addon not enabled ($m/addon.yaml)"
assert_yq $m/addon.yaml '.addon.namespace' openchoreo-control-plane
h=$(render kgateway $charts/kgateway -n openchoreo-control-plane -f $m/values.yaml)
check "$h" openchoreo-control-plane

# workers: next to the OpenChoreo data plane, like upstream; rendered like Kargo's render-addon (includeCRDs,
# skipTests) for every env overlay
w=$config/addons/workers/kgateway
[ -f $w/addon.yaml ] && [ ! -e $w/addon.yaml.disabled ] || fail "worker kgateway addon not enabled ($w/addon.yaml)"
assert_yq $w/addon.yaml '.addon.namespace' openchoreo-data-plane
assert_yq $w/addon.yaml '.addon.namespace' "$(yq '.addon.namespace' $config/addons/workers/openchoreo-data-plane/addon.yaml*)"
for env in dev test prod; do
  f=(-f $w/values.yaml); [ ! -f $w/envs/$env.values.yaml ] || f+=(-f $w/envs/$env.values.yaml)
  r=$(render kgateway $charts/kgateway -n openchoreo-data-plane --include-crds --skip-tests "${f[@]}")
  check "$r" openchoreo-data-plane
  # Kargo commits the render to rendered/<env>: it must be reproducible (no chart-generated certs/secrets/randomness),
  # else every promotion is a diff and the workers churn
  r2=$(render kgateway $charts/kgateway -n openchoreo-data-plane --include-crds --skip-tests "${f[@]}")
  cmp -s "$r" "$r2" || fail "kgateway worker render ($env) is not deterministic"
done
