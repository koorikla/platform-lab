#!/usr/bin/env bash
# #13: every worker in fleet/clusters/ is registered in OpenChoreo by the cluster chart: ClusterDataPlane + Environment
# (Backstage lists both before any agent connects), plus the agent's identity. Per-cluster CA on the hub (the
# cluster-gateway takes planeID from the URL and checks only the chain, so a shared CA would let any agent claim any
# plane); the client cert and the gateway's server CA go to OpenBao secret/clusters/<name>/* for the worker to pull
# (#14). Rendered only when the hub serves the OpenChoreo CRDs (Argo passes the cluster's API versions to helm), so the
# registration follows the openchoreo-control-plane addon being enabled (addon.yaml vs addon.yaml.disabled).
source "$(dirname "$0")/lib.sh"
oc=(--api-versions openchoreo.dev/v1alpha1/ClusterDataPlane --api-versions openchoreo.dev/v1alpha1/Environment)
ocKinds='select(.apiVersion | test("^openchoreo.dev/"))'
ns=openchoreo-control-plane

# --- no OpenChoreo on the hub -> nothing OpenChoreo-related (cluster apps must keep syncing without it)
w=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$w" "[$ocKinds] | length" 0
assert_yq "$w" "[select(.metadata.namespace==\"$ns\")] | length" 0

o=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml "${oc[@]}")
# --- ClusterDataPlane: invariant 1 (name == planeID == cluster name); client CA from the hub-side secret, no key
cdp='select(.kind=="ClusterDataPlane")'
assert_yq "$o" "[$cdp] | length" 1
assert_yq "$o" "$cdp | .apiVersion" openchoreo.dev/v1alpha1
assert_yq "$o" "$cdp | .metadata.name + \"/\" + .spec.planeID" dev1/dev1
assert_yq "$o" "$cdp | .metadata.namespace" null
assert_yq "$o" "$cdp | .spec.clusterAgent.clientCA.secretKeyRef | .namespace + \"/\" + .name + \"#\" + .key" \
  "$ns/dev1-openchoreo-agent-ca#ca.crt"
assert_yq "$o" "$cdp | .spec.clusterAgent.clientCA.value" null
# secretStoreRef names a ClusterSecretStore ON THE WORKER (CRD description); none exists yet -> omitted (optional)
assert_yq "$o" "$cdp | .spec.secretStoreRef" null
# fleet labels flow to OpenChoreo too (invariant 2: from the fleet file only)
assert_yq "$o" "$cdp | .metadata.labels[\"platform.lab/env\"] + \"/\" + .metadata.labels[\"platform.lab/ring\"]" dev/stable
# ingress through the data plane's Gateway (openchoreo-data-plane chart: gateway-default, listener http, port 80)
gw="$cdp | .spec.gateway.ingress.external"
assert_yq "$o" "$gw | .namespace + \"/\" + .name" openchoreo-data-plane/gateway-default
assert_yq "$o" "$gw | .http.listenerName + \":\" + (.http.port | tostring)" http:80
assert_yq "$o" "$gw | .http.host" dev1.apps.lab.localhost

# --- Environment <name> in the org namespace, bound to that plane (dataPlaneRef is immutable)
env='select(.kind=="Environment")'
assert_yq "$o" "[$env] | length" 1
assert_yq "$o" "$env | .metadata.namespace + \"/\" + .metadata.name" default/dev1
assert_yq "$o" "$env | .spec.dataPlaneRef.kind + \"/\" + .spec.dataPlaneRef.name" ClusterDataPlane/dev1
assert_yq "$o" "$env | .spec.isProduction" false
assert_yq "$o" "$env | .metadata.annotations[\"openchoreo.dev/display-name\"]" "dev / dev1"
# openchoreo-api (and so Backstage) lists Environments only in namespaces the control-plane umbrella labels
c=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n $ns \
  -f $config/addons/management/openchoreo-control-plane/values.yaml)
assert_yq "$c" 'select(.kind=="Namespace" and .metadata.name=="default") | .metadata.labels["openchoreo.dev/control-plane"]' true
assert_yq "$(render p $charts/cluster -f $config/fleet/clusters/prod/prod1.yaml.disabled "${oc[@]}")" \
  "$env | .spec.isProduction" true
# dev2 may be disabled for a while (#83): the file's content is what matters here
d2f=$config/fleet/clusters/dev/dev2.yaml; [ -f "$d2f" ] || d2f=$d2f.disabled
d2=$(render dev2 $charts/cluster -f "$d2f" "${oc[@]}")
assert_yq "$d2" "$cdp | .metadata.labels[\"platform.lab/ring\"]" canary
assert_yq "$d2" "$env | .spec.dataPlaneRef.name" dev2

# --- per-cluster CA chain in the cluster-gateway's namespace (CA keys never leave the hub)
cert() { echo "select(.kind==\"Certificate\" and .metadata.name==\"$1\")"; }
assert_yq "$o" "[select(.kind==\"Certificate\" or .kind==\"Issuer\") | .metadata.namespace] | unique | join(\",\")" \
  "argocd,$ns"
assert_yq "$o" "select(.kind==\"Issuer\" and .metadata.name==\"dev1-openchoreo-agent-selfsigned\") | .spec.selfSigned" '{}'
ca=$(cert dev1-openchoreo-agent-ca)
assert_yq "$o" "$ca | .spec.isCA" true
assert_yq "$o" "$ca | .spec.secretName" dev1-openchoreo-agent-ca
assert_yq "$o" "$ca | .spec.issuerRef.kind + \"/\" + .spec.issuerRef.name" Issuer/dev1-openchoreo-agent-selfsigned
assert_yq "$o" "select(.kind==\"Issuer\" and .metadata.name==\"dev1-openchoreo-agent-ca\") | .spec.ca.secretName" \
  dev1-openchoreo-agent-ca
tls=$(cert dev1-openchoreo-agent-tls)
assert_yq "$o" "$tls | .spec.commonName" dev1
assert_yq "$o" "$tls | .spec.usages | join(\",\")" "client auth"
assert_yq "$o" "$tls | .spec.issuerRef.kind + \"/\" + .spec.issuerRef.name" Issuer/dev1-openchoreo-agent-ca
assert_yq "$o" "$tls | .spec.isCA" null
# upstream cluster-agent loads its cert once at startup (agent.go:83): renew rarely; #14 restarts it on Secret change
assert_yq "$o" "$tls | .spec.duration + \"/\" + .spec.renewBefore" 8760h/720h

# --- to OpenBao (hub-local PushSecrets); the worker pulls them (#14). Never the CA's secret, never the gateway's key.
#     No ca.crt with the client cert: that is the agent's own CA, useless on the worker and easy to mistake for the
#     gateway CA (--server-ca), which has its own path.
ps='select(.kind=="PushSecret" and .metadata.namespace=="'$ns'")'
assert_yq "$o" "[$ps | .spec.selector.secret.name] | sort | join(\",\")" cluster-gateway-ca,dev1-openchoreo-agent-tls
assert_yq "$o" "[$ps | .spec.secretStoreRefs[] | .kind + \"/\" + .name] | unique | join(\",\")" ClusterSecretStore/openbao
agent="$ps | select(.spec.selector.secret.name==\"dev1-openchoreo-agent-tls\")"
assert_yq "$o" "$agent | [.spec.data[].match | .secretKey + \">\" + .remoteRef.remoteKey + \"#\" + .remoteRef.property] | sort | join(\",\")" \
  "tls.crt>clusters/dev1/openchoreo-agent#tls.crt,tls.key>clusters/dev1/openchoreo-agent#tls.key"
gca="$ps | select(.spec.selector.secret.name==\"cluster-gateway-ca\")"
assert_yq "$o" "$gca | [.spec.data[].match | .secretKey + \">\" + .remoteRef.remoteKey + \"#\" + .remoteRef.property] | join(\",\")" \
  "ca.crt>clusters/dev1/openchoreo-gateway-ca#ca.crt"
assert_yq "$o" "[select(.kind==\"PushSecret\") | .spec.selector.secret.name | select(test(\"-ca$\") and . != \"cluster-gateway-ca\")] | length" 0
# the gateway CA we push is the one that signs the cluster-gateway's server cert (the cert with dnsName mgmt-lb)
srvIssuer=$(yq 'select(.kind=="Certificate" and (.spec.dnsNames // [] | contains(["mgmt-lb"]))) | .spec.issuerRef.name' "$c")
[ -n "$srvIssuer" ] || fail "no cluster-gateway server Certificate with dnsName mgmt-lb in the control-plane render"
assert_yq "$c" "select(.kind==\"Issuer\" and .metadata.name==\"$srvIssuer\") | .spec.ca.secretName" cluster-gateway-ca
# ClusterSecretStore openbao admits PushSecrets only from hubWriter.namespaces (platform-charts/openbao)
b=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
for n in $(yq eval-all '[select(.kind=="PushSecret") | .metadata.namespace] | unique | .[]' "$o"); do
  assert_yq "$b" "select(.kind==\"ClusterSecretStore\" and .metadata.name==\"openbao\") | .spec.conditions[0].namespaces | contains([\"$n\"])" true
done

# --- the hub is the control plane, not a data plane
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml "${oc[@]}")
assert_yq "$h" "[$ocKinds] | length" 0
assert_yq "$h" "[select(.kind==\"Certificate\" or .kind==\"Issuer\" or .kind==\"PushSecret\")] | length" 0

# --- invariant 1 for every cluster file: ClusterDataPlane name == planeID == Environment name == fleet name
for f in $config/fleet/clusters/*/*.yaml*; do
  [ "$(yq '.role // "worker"' "$f")" = worker ] || continue
  n=$(yq '.name' "$f")
  r=$(render "$n" $charts/cluster -f "$f" "${oc[@]}")
  assert_yq "$r" "[$cdp | .metadata.name, .spec.planeID] + [$env | .metadata.name, .spec.dataPlaneRef.name] | unique | join(\",\")" "$n"
done
