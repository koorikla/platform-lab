#!/usr/bin/env bash
# #12: OpenChoreo control plane 1.2.5 on the hub. Values = upstream install/k3d/multi-cluster/values-cp.yaml @ v1.2.5
# (hostnames/ports as upstream k3d: http://<x>.openchoreo.localhost:8080), plus the lab's cluster-gateway exposure:
# workers dial mgmt-lb:30843 (hub CAPD LB frontend -> NodePort 30843), so the gateway cert must cover `mgmt-lb`.
# Secrets: test_openchoreo_secrets.sh. Gateway Service/DNS/make ui: test_hub_dns_ui.sh.
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/openchoreo-control-plane
[ -f $a/addon.yaml ] && [ ! -e $a/addon.yaml.disabled ] || fail "control-plane addon not enabled ($a/addon.yaml)"
assert_yq $a/addon.yaml '.addon.namespace + "/" + .addon.releaseName' openchoreo-control-plane/openchoreo-control-plane
assert_yq $charts/openchoreo-control-plane/Chart.yaml \
  '.dependencies[] | select(.name=="openchoreo-control-plane") | .repository + ":" + .version' oci://ghcr.io/openchoreo/helm-charts:1.2.5
o=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n openchoreo-control-plane -f $a/values.yaml)

# --- upstream k3d hostnames/ports: one URL for browser (make ui) and pods (CoreDNS rewrite), plain http on :8080
assert_yq "$o" 'select(.kind=="HTTPRoute" and .metadata.name=="backstage") | .spec.hostnames | join(",")' openchoreo.localhost
assert_yq "$o" 'select(.kind=="HTTPRoute" and .metadata.name=="openchoreo-api") | .spec.hostnames | join(",")' api.openchoreo.localhost
bs_env() { yq "select(.kind==\"Deployment\" and .metadata.name==\"backstage\") | .spec.template.spec.containers[0].env[] | select(.name==\"$1\") | .value" "$o"; }
base=$(bs_env BACKSTAGE_BASE_URL)
[ "$base" = http://openchoreo.localhost:8080 ] || fail "backstage baseUrl = '$base'"
thunder=http://thunder.openchoreo.localhost:8080
[ "$(bs_env OPENCHOREO_AUTH_AUTHORIZATION_URL)" = $thunder/oauth2/authorize ] || fail "authorizationUrl = '$(bs_env OPENCHOREO_AUTH_AUTHORIZATION_URL)'"
[ "$(bs_env OPENCHOREO_AUTH_TOKEN_URL)" = $thunder/oauth2/token ] || fail "tokenUrl = '$(bs_env OPENCHOREO_AUTH_TOKEN_URL)'"
api=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="openchoreo-api-config") | .data["config.yaml"]' "$o")
[ -n "$api" ] || fail "no openchoreo-api-config config.yaml"
assert_yq - '.server.public_url' http://api.openchoreo.localhost:8080 <<<"$api"
assert_yq - '.identity.oidc | [.issuer, .jwks_url, .authorization_endpoint, .token_endpoint] | join(",")' \
  "$thunder,$thunder/oauth2/jwks,$thunder/oauth2/authorize,$thunder/oauth2/token" <<<"$api"
! grep -qE 'https?://[^" ]*\.invalid|https://[a-z.]*openchoreo\.localhost' "$o" || fail "placeholder (.invalid) or https openchoreo.localhost URL rendered"

# --- Thunder (#10) is the IdP: same issuer, the Backstage client it registers, redirect back to this baseUrl
t=$(render thunder $charts/thunder -n thunder -f $config/addons/management/thunder/values.yaml)
tcfg=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-config-map") | .data["deployment.yaml"]' "$t")
assert_yq - '.server.public_url' "$thunder" <<<"$tcfg"
[ "$(bs_env OPENCHOREO_AUTH_CLIENT_ID)" = openchoreo-backstage-client ] || fail "backstage client id = '$(bs_env OPENCHOREO_AUTH_CLIENT_ID)'"
bs=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-bootstrap") | .data["51-backstage-app.sh"]' "$t")
grep -qF '"client_id": "openchoreo-backstage-client"' <<<"$bs" || fail "Thunder registers no openchoreo-backstage-client"
grep -qF "\"$base/api/auth/openchoreo-auth/handler/frame\"" <<<"$bs" || fail "Thunder's Backstage redirect_uri is not under $base"
# the client secret Backstage sends = the one Thunder registered (both from OpenBao, test_openchoreo_secrets.sh)
cs='select(.kind=="Deployment" and .metadata.name=="backstage") | .spec.template.spec.containers[0].env[] | select(.name=="OPENCHOREO_AUTH_CLIENT_SECRET") | .valueFrom.secretKeyRef'
assert_yq "$o" "$cs | .name + \"/\" + .key" backstage-secrets/client-secret
assert_yq "$o" 'select(.kind=="ExternalSecret" and .metadata.name=="backstage-secrets") | .spec.data[] | select(.secretKey=="client-secret") | .remoteRef.key' \
  "$(yq 'select(.kind=="ExternalSecret" and .metadata.name=="thunder-backstage-client") | .spec.data[0].remoteRef.key' "$t")"

# --- cluster-gateway: workers dial wss://mgmt-lb:30843/ws (hub CAPD LB frontend -> this NodePort), not a hostname route
np=$(yq 'select(.kind=="Service" and .metadata.name=="cluster-gateway-external") | .spec.type + ":" + (.spec.ports[] | .port + ":" + .nodePort)' "$o")
[ "$np" = NodePort:8443:30843 ] || fail "cluster-gateway-external = '$np', want NodePort:8443:30843"
assert_yq "$o" '[select(.kind=="TLSRoute")] | length' 0
assert_yq "$o" 'select(.kind=="Gateway") | [.spec.listeners[] | .name + ":" + .port] | join(",")' http:8080
assert_yq "$o" 'select(.kind=="Certificate" and .metadata.name=="cluster-gateway-tls") | .spec.dnsNames | sort | join(",")' \
  cluster-gateway.openchoreo-control-plane.svc,cluster-gateway.openchoreo-control-plane.svc.cluster.local,mgmt-lb
lb=$(yq '.data.value' $config/fleet/base/hub-lb.yaml)
grep -qE '^ *bind \*:30843$' <<<"$lb" || fail "hub-lb.yaml: no frontend bound to :30843"
grep -qF 'JoinHostPort $backend.Address "30843"' <<<"$lb" || fail "hub-lb.yaml: no backend on the nodes' :30843"
# the data plane's agent (#13) dials exactly that
assert_yq $charts/openchoreo-data-plane/values.yaml '.openchoreo-data-plane.clusterAgent.serverUrl' wss://mgmt-lb:30843/ws
# nothing else may claim it (a random pick stole 30443 once, see CLAUDE.md): charts (values + templates) and config
others=$(grep -rlE '\b30843\b' $charts $config | grep -vE "^$charts/openchoreo-(control|data)-plane/|^$config/fleet/base/hub-lb.yaml$" || true)
[ -z "$others" ] || fail "30843 also used by: $others"

# --- the Gateway's own Service: ClusterIP, sized. kgateway defaults to LoadBalancer = k3s servicelb pods binding
#     hostPort 8080 on every hub node (reachable from all workers) plus a random NodePort; make ui and the CoreDNS
#     rewrite only need the ClusterIP. kgateway v2.3.1 reads Gateway.spec.infrastructure.parametersRef (same namespace,
#     group gateway.kgateway.dev, kind GatewayParameters) and deep-merges it over its defaults
#     (pkg/kgateway/deployer/gateway_parameters.go getGatewayParametersForGateway).
ref=$(yq 'select(.kind=="Gateway") | .spec.infrastructure.parametersRef | .group + "/" + .kind + "/" + .name' "$o")
[ "${ref%/*}" = gateway.kgateway.dev/GatewayParameters ] || fail "Gateway parametersRef = '$ref'"
gwp="select(.kind==\"GatewayParameters\" and .metadata.name==\"${ref##*/}\")"
assert_yq "$o" "[$gwp] | length" 1
assert_yq "$o" "$gwp | .apiVersion + \" \" + .metadata.namespace" "gateway.kgateway.dev/v1alpha1 openchoreo-control-plane"
assert_yq "$o" "$gwp | .spec.kube.service.type" ClusterIP
# modest requests, no limits (#67): envoy is the only container of the proxy pod (sds only with istio integration)
assert_yq "$o" "$gwp | .spec.kube.envoyContainer.resources.requests | keys | sort | join(\",\")" cpu,memory
assert_yq "$o" "$gwp | .spec.kube.envoyContainer.resources | has(\"limits\")" false
# the fields exist at the kgateway-crds version the hub runs (kubeconform against its CRD; skipped without kubeconform)
if command -v kubeconform >/dev/null; then
  kg=$(yq '.dependencies[] | select(.name=="kgateway-crds") | .version' $charts/kgateway/Chart.yaml)
  helm dependency build $charts/kgateway >/dev/null || fail "helm dependency build $charts/kgateway"
  crd=$tmp/gwp-crd.yaml
  helm template x $charts/kgateway/charts/kgateway-crds-$kg.tgz --include-crds |
    yq 'select(.metadata.name=="gatewayparameters.gateway.kgateway.dev")' >"$crd"
  [ -s "$crd" ] || fail "kgateway-crds $kg has no GatewayParameters CRD"
  mkdir -p "$tmp/schemas"
  yq -o json '(.spec.versions[] | select(.name=="v1alpha1") | .schema.openAPIV3Schema)
    | (.. | select(tag == "!!map" and has("properties")) | select(has("additionalProperties") == false and has("x-kubernetes-preserve-unknown-fields") == false))
      |= . + {"additionalProperties": false}' "$crd" >"$tmp/schemas/gatewayparameters_v1alpha1.json"
  yq "$gwp" "$o" >"$tmp/gwp.yaml"
  kubeconform -strict -schema-location "$tmp/schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" "$tmp/gwp.yaml" ||
    fail "GatewayParameters does not validate against kgateway-crds $kg"
else
  echo "SKIP: GatewayParameters schema check (kubeconform not on PATH)"
fi

# --- org namespace: openchoreo-api/Backstage only list namespaces labelled control-plane=true (upstream labels `default`
#     imperatively). SSA adds just the label; Argo must never delete or prune `default`.
ns='select(.kind=="Namespace" and .metadata.name=="default")'
assert_yq "$o" "[$ns] | length" 1
assert_yq "$o" "$ns | .metadata.labels[\"openchoreo.dev/control-plane\"]" true
assert_yq "$o" "$ns | .metadata.labels[\"openchoreo.dev/control-plane\"] | tag" '!!str'
assert_yq "$o" "$ns | .metadata.annotations[\"argocd.argoproj.io/sync-options\"] | split(\",\") | sort | join(\",\")" \
  Delete=false,Prune=false,ServerSideApply=true
# default resources (Project, Environments, DeploymentPipeline) are not ours: #13 (per cluster) and Phase 3
assert_yq "$o" '[select(.apiVersion == "openchoreo.dev/*")] | length' 0

# --- hub budget (~15 GB shared by every CAPD node): every long-running container requests cpu + memory
assert_yq "$o" '[select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.resources.requests.cpu == null or .resources.requests.memory == null) | .name] | join(",")' ''
# Argo hooks: only upstream's authz bootstrap (post-install/upgrade -> PostSync, idempotent kubectl apply). Nothing
# PreSync that could wait on a not-yet-running control plane.
assert_yq "$o" '[select(.metadata.annotations["helm.sh/hook"] != null) | .metadata.annotations["helm.sh/hook"]] | unique | join(",")' post-install,post-upgrade
