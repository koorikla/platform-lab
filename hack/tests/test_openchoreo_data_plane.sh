#!/usr/bin/env bash
# #14: OpenChoreo data plane on workers. Split along the addendum's rule (Kargo renders everything versioned; per-cluster
# stamping is identity only, in the CAAPH birth kit):
#   - worker addon openchoreo-data-plane (Kargo, rendered/<env>): upstream chart = cluster-agent + Gateway, plus
#     Reloader to restart the agent when its identity changes. Cluster-agnostic: the plane ID is an env var.
#   - birth kit: the identity (Secret cluster-agent-tls = client cert + plane-id, ConfigMap cluster-gateway-ca).
# The upstream chart can't go into the birth kit: with TLS on it always renders a cert-manager Certificate + Issuer
# (and the Gateway needs Gateway API + kgateway CRDs); all of them arrive as worker addons *through* the birth kit's
# agent, so a birth kit carrying them could never install. This file checks the contract between the two halves.
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
  assert_yq "$o" "$c | .args[] | select(test(\"^--plane-id=\"))" '--plane-id=$(PLANE_ID)'   # kubelet expands $(VAR)
  assert_yq "$o" "$c | .env[] | select(.name==\"PLANE_ID\") | .valueFrom.secretKeyRef | .name + \"#\" + .key" \
    "$tlsSecret#$(yq "$tlsES | .spec.externalSecretSpec.target.template.data | keys | .[0]" "$k")"
  ! grep -q dev1 "$o" || fail "rendered data plane ($env) names a cluster: identity belongs to the birth kit"
  assert_yq "$o" "$c | .args[] | select(test(\"^--tls-enabled=\"))" --tls-enabled=true
  assert_yq "$o" "$d | .spec.template.spec.volumes[] | select(.name==\"client-certs\") | .secret.secretName" "$tlsSecret"
  assert_yq "$o" "$d | .spec.template.spec.volumes[] | select(.name==\"server-ca\") | .configMap.name" "$caConfigMap"
  # ... and the hub endpoint the birth kit and the control plane agree on (hub LB frontend -> cluster-gateway NodePort)
  hub=$(yq '.hub.host' $kit/values.yaml)
  port=$(yq '.["openchoreo-control-plane"].clusterGateway.service.nodePort' $charts/openchoreo-control-plane/values.yaml)
  assert_yq "$o" "$c | .args[] | select(test(\"^--server-url=\"))" "--server-url=wss://$hub:$port/ws"
  # the chart always renders a Certificate while TLS is on; it must not write into the Secret ESO owns (both
  # controllers would overwrite each other and the agent would present a self-signed cert)
  assert_yq "$o" "[select(.kind==\"Certificate\") | .spec.secretName | select(. == \"$tlsSecret\")] | length" 0
  assert_yq "$o" '[select(.kind=="Certificate") | .metadata.name] | join(",")' cluster-agent-dataplane-tls

  # --- restart on identity change: upstream cluster-agent loads the cert once at startup (agent.go:83)
  assert_yq "$o" "$d | .spec.template.metadata.annotations[\"secret.reloader.stakater.com/reload\"]" "$tlsSecret"
  assert_yq "$o" "$d | .spec.template.metadata.annotations[\"configmap.reloader.stakater.com/reload\"]" "$caConfigMap"
  r='select(.kind=="Deployment" and .metadata.name=="reloader")'
  assert_yq "$o" "$r | .spec.template.spec.containers[0].args[] | select(test(\"^--reload-strategy=\"))" \
    --reload-strategy=annotations       # a pod-template annotation, which Argo's diff ignores (not an env var)
  # only this namespace: Roles, no ClusterRole, KUBERNETES_NAMESPACE set -> watches secrets/configmaps here only
  assert_yq "$o" "[select(.kind==\"ClusterRole\" or .kind==\"ClusterRoleBinding\") | .metadata.name | select(test(\"reloader\"))] | length" 0
  assert_yq "$o" "$r | .spec.template.spec.containers[0].env[] | select(.name==\"KUBERNETES_NAMESPACE\") | .valueFrom.fieldRef.fieldPath" \
    metadata.namespace

  # --- ingress: the Gateway the ClusterDataPlane names (cluster chart: gateway-default, listener http :80), no TLS
  gw='select(.kind=="Gateway")'
  assert_yq "$o" "$gw | .metadata.name" "$(yq '.openchoreo.dataPlaneGateway.name' $charts/cluster/values.yaml)"
  assert_yq "$o" "$gw | [.spec.listeners[] | .name + \":\" + .port] | join(\",\")" http:80
  # its proxy like the hub's (test_openchoreo_control_plane.sh): ClusterIP (no servicelb pod binding :80 on every
  # worker node), sized envoy, requests only; the chart's own infrastructure label survives the merge
  ref=$(yq "$gw | .spec.infrastructure.parametersRef | .group + \"/\" + .kind + \"/\" + .name" "$o")
  [ "${ref%/*}" = gateway.kgateway.dev/GatewayParameters ] || fail "Gateway parametersRef = '$ref'"
  assert_yq "$o" "$gw | .spec.infrastructure.labels[\"openchoreo.dev/system-component\"]" gateway
  gwp="select(.kind==\"GatewayParameters\" and .metadata.name==\"${ref##*/}\")"
  assert_yq "$o" "[$gwp] | length" 1
  assert_yq "$o" "$gwp | .apiVersion + \" \" + .metadata.namespace" "gateway.kgateway.dev/v1alpha1 $ns"
  assert_yq "$o" "$gwp | .spec.kube.service.type" ClusterIP
  assert_yq "$o" "$gwp | .spec.kube.envoyContainer.resources.requests | keys | sort | join(\",\")" cpu,memory
  assert_yq "$o" "$gwp | .spec.kube.envoyContainer.resources | has(\"limits\")" false

  # --- nothing optional (#76: the Docker VM is CPU-bound): no webhook cert for a webhook the data plane doesn't run,
  # agent + reloader only, both with small requests and bounded limits
  assert_yq "$o" '[select(.kind=="Certificate" and .spec.secretName=="webhook-server-cert")] | length' 0
  assert_yq "$o" '[select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | .metadata.name] | sort | join(",")' \
    cluster-agent-dataplane,reloader
  for w in cluster-agent-dataplane reloader; do
    res="select(.kind==\"Deployment\" and .metadata.name==\"$w\") | .spec.template.spec.containers[0].resources"
    assert_yq "$o" "$res | [.requests.cpu, .requests.memory, .limits.cpu, .limits.memory] | map(select(. != null)) | length" 4
  done
  assert_yq "$o" "[select(.metadata.namespace != null) | .metadata.namespace] | unique | join(\",\")" "$ns"

  # --- Kargo commits this render: reproducible, or every promotion is a diff
  o2=$(render "$(yq '.addon.releaseName' $a/addon.yaml)" $charts/"$(yq '.addon.chart' $a/addon.yaml)" -n "$ns" \
    --include-crds --skip-tests "${f[@]}")
  cmp -s "$o" "$o2" || fail "openchoreo-data-plane render ($env) is not deterministic"
done
