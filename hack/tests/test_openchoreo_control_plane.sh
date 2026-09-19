#!/usr/bin/env bash
# #12: OpenChoreo control plane 1.2.5 on the hub. Values = upstream install/k3d/multi-cluster/values-cp.yaml @ v1.2.5
# (hostnames/ports as upstream k3d: http://<x>.openchoreo.localhost:8080), plus the lab's cluster-gateway exposure:
# workers dial mgmt-lb:30843 (hub CAPD LB frontend -> NodePort 30843), so the gateway cert must cover `mgmt-lb`.
# What the chart renders (URLs, gateway, GatewayParameters, org namespace, budget, hooks): its unit tests
# (repos/platform-charts/openchoreo-control-plane/tests/). Here: the addon, the render with hub values, and the
# contracts with Thunder, the hub LB, the data plane and the kgateway CRDs.
# Secrets: test_openchoreo_secrets.sh. Gateway Service/DNS/make ui: test_hub_dns_ui.sh.
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/openchoreo-control-plane
[ -f $a/addon.yaml ] && [ ! -e $a/addon.yaml.disabled ] || fail "control-plane addon not enabled ($a/addon.yaml)"
assert_yq $a/addon.yaml '.addon.namespace + "/" + .addon.releaseName' openchoreo-control-plane/openchoreo-control-plane
assert_yq $charts/openchoreo-control-plane/Chart.yaml \
  '.dependencies[] | select(.name=="openchoreo-control-plane") | .repository + ":" + .version' oci://ghcr.io/openchoreo/helm-charts:1.2.5
o=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n openchoreo-control-plane -f $a/values.yaml)
! grep -qE 'https?://[^" ]*\.invalid|https://[a-z.]*openchoreo\.localhost' "$o" || fail "placeholder (.invalid) or https openchoreo.localhost URL rendered"

# --- Thunder (#10) is the IdP: Backstage and openchoreo-api trust its issuer, Backstage logs in as the client Thunder
#     registers, and Thunder redirects back to Backstage's baseUrl
bs_env() { yq "select(.kind==\"Deployment\" and .metadata.name==\"backstage\") | .spec.template.spec.containers[0].env[] | select(.name==\"$1\") | .value" "$o"; }
base=$(bs_env BACKSTAGE_BASE_URL)
t=$(render thunder $charts/thunder -n thunder -f $config/addons/management/thunder/values.yaml)
tcfg=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-config-map") | .data["deployment.yaml"]' "$t")
thunder=$(yq '.server.public_url' <<<"$tcfg")
[ "$(bs_env OPENCHOREO_AUTH_AUTHORIZATION_URL)" = "$thunder/oauth2/authorize" ] || fail "authorizationUrl = '$(bs_env OPENCHOREO_AUTH_AUTHORIZATION_URL)'"
[ "$(bs_env OPENCHOREO_AUTH_TOKEN_URL)" = "$thunder/oauth2/token" ] || fail "tokenUrl = '$(bs_env OPENCHOREO_AUTH_TOKEN_URL)'"
api=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="openchoreo-api-config") | .data["config.yaml"]' "$o")
[ -n "$api" ] || fail "no openchoreo-api-config config.yaml"
assert_yq - '.identity.oidc | [.issuer, .jwks_url, .authorization_endpoint, .token_endpoint] | join(",")' \
  "$thunder,$thunder/oauth2/jwks,$thunder/oauth2/authorize,$thunder/oauth2/token" <<<"$api"
bs=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-bootstrap") | .data["51-backstage-app.sh"]' "$t")
grep -qF "\"client_id\": \"$(bs_env OPENCHOREO_AUTH_CLIENT_ID)\"" <<<"$bs" || fail "Thunder registers no client '$(bs_env OPENCHOREO_AUTH_CLIENT_ID)'"
grep -qF "\"$base/api/auth/openchoreo-auth/handler/frame\"" <<<"$bs" || fail "Thunder's Backstage redirect_uri is not under $base"
# the client secret Backstage sends = the one Thunder registered (both from OpenBao, test_openchoreo_secrets.sh)
cs='select(.kind=="Deployment" and .metadata.name=="backstage") | .spec.template.spec.containers[0].env[] | select(.name=="OPENCHOREO_AUTH_CLIENT_SECRET") | .valueFrom.secretKeyRef'
assert_yq "$o" "select(.kind==\"ExternalSecret\" and .spec.target.name==\"$(yq "$cs | .name" "$o")\") | .spec.data[] | select(.secretKey==\"$(yq "$cs | .key" "$o")\") | .remoteRef.key" \
  "$(yq 'select(.kind=="ExternalSecret" and .metadata.name=="thunder-backstage-client") | .spec.data[0].remoteRef.key' "$t")"

# --- cluster-gateway: workers dial wss://mgmt-lb:<nodePort>/ws through the hub CAPD LB
np=$(yq 'select(.kind=="Service" and .metadata.name=="cluster-gateway-external") | .spec.ports[0].nodePort' "$o")
[ "$np" = 30843 ] || fail "cluster-gateway-external nodePort with hub values = '$np', want 30843"
lb=$(yq '.data.value' $config/fleet/base/hub-lb.yaml)
grep -qE "^ *bind \*:$np\$" <<<"$lb" || fail "hub-lb.yaml: no frontend bound to :$np"
grep -qF "JoinHostPort \$backend.Address \"$np\"" <<<"$lb" || fail "hub-lb.yaml: no backend on the nodes' :$np"
# the data plane's agent (#13) dials exactly that
assert_yq $charts/openchoreo-data-plane/values.yaml '.openchoreo-data-plane.clusterAgent.serverUrl' "wss://mgmt-lb:$np/ws"
# nothing else may claim it (a random pick stole 30443 once, see CLAUDE.md): charts (values + templates) and config
others=$(grep -rlE "\b$np\b" $charts $config | grep -vE "^$charts/openchoreo-(control|data)-plane/|^$config/fleet/base/hub-lb.yaml$" || true)
[ -z "$others" ] || fail "$np also used by: $others"

# --- the Gateway's GatewayParameters (kgateway v2.3.1 reads Gateway.spec.infrastructure.parametersRef, same namespace,
#     and deep-merges it over its defaults): its fields exist at the kgateway-crds version the hub runs (kubeconform
#     against that CRD; skipped without kubeconform)
ref=$(yq 'select(.kind=="Gateway") | .spec.infrastructure.parametersRef | .group + "/" + .kind + "/" + .name' "$o")
gwp="select(.kind==\"GatewayParameters\" and .metadata.name==\"${ref##*/}\")"
assert_yq "$o" "[$gwp] | length" 1
if command -v kubeconform >/dev/null; then
  kg=$(yq '.dependencies[] | select(.name=="kgateway-crds") | .version' $charts/kgateway/Chart.yaml)
  deps $charts/kgateway
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
