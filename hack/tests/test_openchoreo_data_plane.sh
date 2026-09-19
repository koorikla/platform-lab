#!/usr/bin/env bash
# #14: OpenChoreo data plane on workers. Split along the addendum's rule (Kargo renders everything versioned; per-cluster
# stamping is identity only, in the CAAPH birth kit):
#   - worker addon openchoreo-data-plane (Kargo, rendered/<env>): upstream chart = cluster-agent + Gateway, plus
#     Reloader to restart the agent when its identity changes. Cluster-agnostic: the plane ID is an env var.
#   - birth kit: the identity (Secret cluster-agent-tls = client cert + plane-id, ConfigMap cluster-gateway-ca).
# The upstream chart can't go into the birth kit: with TLS on it always renders a cert-manager Certificate + Issuer
# (and the Gateway needs Gateway API + kgateway CRDs); all of them arrive as worker addons *through* the birth kit's
# agent, so a birth kit carrying them could never install. Each chart on its own: its unit tests
# (openchoreo-data-plane/tests/data_plane_test.yaml, worker-birth-kit/tests/openchoreo_identity_test.yaml). This file
# checks the contract between the two halves, the hub endpoint, and every env render as Kargo produces it.
source "$(dirname "$0")/lib.sh"
a=$config/addons/workers/openchoreo-data-plane
kit=$charts/worker-birth-kit
[ -f $a/addon.yaml ] && [ ! -e $a/addon.yaml.disabled ] || fail "worker addon openchoreo-data-plane not enabled ($a/addon.yaml)"
ns=$(yq '.addon.namespace' $a/addon.yaml)
[ "$ns" = openchoreo-data-plane ] || fail "addon namespace $ns"
# the ClusterDataPlane (cluster chart) points at the Gateway in this namespace; kgateway lives there too (#8)
assert_yq $charts/cluster/values.yaml '.openchoreo.dataPlaneGateway.namespace' "$ns"
assert_yq $config/addons/workers/kgateway/addon.yaml '.addon.namespace' "$ns"

# the birth kit's side of the contract (identity for dev1, as CAAPH renders it)
k=$(render worker-birth-kit $kit -n argocd --set clusterName=dev1)
tlsES='select(.kind=="ClusterExternalSecret" and .metadata.name=="openchoreo-agent-tls")'
caES='select(.kind=="ClusterExternalSecret" and .metadata.name=="openchoreo-gateway-ca")'
assert_yq "$k" "$tlsES | .spec.namespaceSelectors[0].matchLabels[\"kubernetes.io/metadata.name\"]" "$ns"
assert_yq "$k" "$caES | .spec.namespaceSelectors[0].matchLabels[\"kubernetes.io/metadata.name\"]" "$ns"
tlsSecret=$(yq "$tlsES | .spec.externalSecretSpec.target.name" "$k")
caConfigMap=$(yq "$caES | .spec.externalSecretSpec.target.name" "$k")

# every environment Kargo renders (the envs of the kargo-pipeline stages, like hack/lint.sh)
for env in $(yq "[.stages[].env] | unique | .[]" $charts/kargo-pipeline/values.yaml); do
  f=(-f "$a/values.yaml"); [ ! -f "$a/envs/$env.values.yaml" ] || f+=(-f "$a/envs/$env.values.yaml")
  # as Kargo's render-addon renders it (includeCRDs, skipTests, release/namespace from addon.yaml)
  o=$(render "$(yq '.addon.releaseName' $a/addon.yaml)" $charts/"$(yq '.addon.chart' $a/addon.yaml)" -n "$ns" \
    --include-crds --skip-tests "${f[@]}")

  # --- cluster-agent: identity only from the birth kit's objects; the render itself names no cluster
  d='select(.kind=="Deployment" and .metadata.name=="cluster-agent-dataplane")'
  c="$d | .spec.template.spec.containers[] | select(.name==\"agent\")"
  assert_yq "$o" "$c | .env[] | select(.name==\"PLANE_ID\") | .valueFrom.secretKeyRef | .name + \"#\" + .key" \
    "$tlsSecret#$(yq "$tlsES | .spec.externalSecretSpec.target.template.data | keys | .[0]" "$k")"
  ! grep -q dev1 "$o" || fail "rendered data plane ($env) names a cluster: identity belongs to the birth kit"
  assert_yq "$o" "$d | .spec.template.spec.volumes[] | select(.name==\"client-certs\") | .secret.secretName" "$tlsSecret"
  assert_yq "$o" "$d | .spec.template.spec.volumes[] | select(.name==\"server-ca\") | .configMap.name" "$caConfigMap"
  assert_yq "$o" "$d | .spec.template.metadata.annotations[\"secret.reloader.stakater.com/reload\"]" "$tlsSecret"
  assert_yq "$o" "$d | .spec.template.metadata.annotations[\"configmap.reloader.stakater.com/reload\"]" "$caConfigMap"
  # ... and the hub endpoint the birth kit and the control plane agree on (hub LB frontend -> cluster-gateway NodePort)
  hub=$(yq '.hub.host' $kit/values.yaml)
  port=$(yq '.["openchoreo-control-plane"].clusterGateway.service.nodePort' $charts/openchoreo-control-plane/values.yaml)
  assert_yq "$o" "$c | .args[] | select(test(\"^--server-url=\"))" "--server-url=wss://$hub:$port/ws"
  # no Certificate in the render may write into the Secret ESO owns (both controllers would overwrite each other)
  assert_yq "$o" "[select(.kind==\"Certificate\") | .spec.secretName | select(. == \"$tlsSecret\")] | length" 0
  assert_yq "$o" '[select(.kind=="Certificate") | .metadata.name] | join(",")' cluster-agent-dataplane-tls
  assert_yq "$o" '[select(.kind=="Certificate" and .spec.secretName=="webhook-server-cert")] | length' 0
  # the Gateway the ClusterDataPlane names (cluster chart)
  assert_yq "$o" 'select(.kind=="Gateway") | .metadata.name' "$(yq '.openchoreo.dataPlaneGateway.name' $charts/cluster/values.yaml)"
  # whole render (#76, the Docker VM is CPU-bound): agent + reloader only, nothing cluster-wide for Reloader,
  # everything namespaced in the addon namespace
  assert_yq "$o" '[select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .metadata.name] | sort | join(",")' \
    cluster-agent-dataplane,reloader
  assert_yq "$o" "[select(.kind==\"ClusterRole\" or .kind==\"ClusterRoleBinding\") | .metadata.name | select(test(\"reloader\"))] | length" 0
  assert_yq "$o" "[select(.metadata.namespace != null) | .metadata.namespace] | unique | join(\",\")" "$ns"

  # --- Kargo commits this render: reproducible, or every promotion is a diff
  o2=$(render "$(yq '.addon.releaseName' $a/addon.yaml)" $charts/"$(yq '.addon.chart' $a/addon.yaml)" -n "$ns" \
    --include-crds --skip-tests "${f[@]}")
  cmp -s "$o" "$o2" || fail "openchoreo-data-plane render ($env) is not deterministic"
done
