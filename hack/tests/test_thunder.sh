#!/usr/bin/env bash
# Thunder IdP on the hub (upstream OpenChoreo 1.2.5 k3d values). Its PVC hook also needs the argocd-cm PVC health
# override (test_argocd_pvc_health.sh); its Backstage client secret comes from OpenBao (#9 contract).
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/thunder
assert_yq $a/addon.yaml '.addon.namespace' thunder
assert_yq $a/addon.yaml '.addon.releaseName' thunder
assert_yq $charts/thunder/Chart.yaml '.dependencies[] | select(.name=="thunder") | .repository + ":" + .version' \
  oci://ghcr.io/asgardeo/helm-charts:0.28.0   # = THUNDER_VERSION in upstream install/k3d/k3d-install.sh @ v1.2.5
o=$(render thunder $charts/thunder -n thunder -f $a/values.yaml)

# sqlite = one writer: single replica, no HPA/PDB, no nginx Ingress, no chart-owned Gateway
assert_yq "$o" '[select(.kind=="Deployment")] | length' 1
assert_yq "$o" 'select(.kind=="Deployment") | .spec.replicas' 1
assert_yq "$o" '[select(.kind=="HorizontalPodAutoscaler" or .kind=="PodDisruptionBudget" or .kind=="Ingress" or .kind=="Gateway")] | length' 0

# hostnames/issuer exactly as upstream: one URL for browser and pods (#11: CoreDNS rewrite + port-forward on 8080)
assert_yq "$o" 'select(.kind=="HTTPRoute") | .spec.hostnames | join(",")' thunder.openchoreo.localhost
assert_yq "$o" 'select(.kind=="HTTPRoute") | .spec.parentRefs[0].namespace + "/" + .spec.parentRefs[0].name' \
  openchoreo-control-plane/gateway-default
assert_yq "$o" 'select(.kind=="HTTPRoute") | .spec.rules[0].backendRefs[0] | .name + ":" + .port' thunder-service:8090
cfg=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-config-map") | .data["deployment.yaml"]' "$o")
assert_yq - '.server.public_url' http://thunder.openchoreo.localhost:8080 <<<"$cfg"
assert_yq - '.database | [.config.type, .runtime.type, .user.type] | unique | join(",")' sqlite <<<"$cfg"
# browser-side token exchange (PKCE) needs CORS for Backstage + the Kargo UI port of `make ui` (#19); Argo CD
# exchanges its code server-side (v3.5), so no origin for it
assert_yq - '.cors.allowed_origins | sort | join(",")' \
  http://localhost:7007,http://localhost:8091,http://openchoreo.localhost:8080 <<<"$cfg"

# Helm hooks become Argo sync hooks; exactly these. hook-failed (Argo: HookFailed) on the PVC and the ExternalSecret
# keeps them across SUCCESSFUL syncs (BeforeHookCreation would re-create them every sync = empty PVC). Caveat: a FAILED
# sync operation deletes every HookFailed hook, succeeded ones included (gitops-engine hooksPendingDeletionFailed), so
# the PVC goes Terminating (pvc-protection holds it until the pod restarts). See the values.yaml header.
# The setup Job has no delete policy (setup.preserveJob): Argo's default BeforeHookCreation re-creates it every sync,
# so a failed Job can't block later syncs, and the finished Job and its logs stay until the next sync.
# No DB-credentials Secret hook: sqlite has no password. The ExternalSecret is ours (Backstage client secret, below).
hooks='ConfigMap/thunder-bootstrap:pre-install:-10:,ConfigMap/thunder-setup-config-map:pre-install:-10:,ExternalSecret/thunder-backstage-client:pre-install:-20:hook-failed,Job/thunder-setup:pre-install:-5:,PersistentVolumeClaim/thunder-database-pvc:pre-install:-15:hook-failed,ServiceAccount/thunder-service-account:pre-install:-10:'
assert_yq "$o" '[select(.metadata.annotations["helm.sh/hook"] != null) | .kind + "/" + .metadata.name + ":" + .metadata.annotations["helm.sh/hook"] + ":" + .metadata.annotations["helm.sh/hook-weight"] + ":" + (.metadata.annotations["helm.sh/hook-delete-policy"] // "")] | sort | join(",")' "$hooks"
assert_yq "$o" '[select(.metadata.annotations["argocd.argoproj.io/hook"] != null)] | length' 0
assert_yq "$o" 'select(.kind=="Job") | .spec.ttlSecondsAfterFinished' null   # kept until the next sync re-creates it
# the setup Job is the PVC's first consumer (local-path is WaitForFirstConsumer), so it must mount it
assert_yq "$o" 'select(.kind=="Job") | .spec.template.spec.volumes[] | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName' thunder-database-pvc

# Backstage OAuth client secret (#9 contract): generated in-cluster, OpenBao secret/openchoreo/backstage-client-secret
# (property value), read through ClusterSecretStore `default`. PreSync hook at a lower weight than the Job: Argo waits
# until the ExternalSecret is Ready (= Secret written) before the Job starts. hook-failed: fewer re-creations than
# BeforeHookCreation (same caveat as above: a failed sync deletes it; the retry re-creates it, harmless).
es='select(.kind=="ExternalSecret" and .metadata.name=="thunder-backstage-client")'
assert_yq "$o" "$es | .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name" ClusterSecretStore/default
assert_yq "$o" "$es | .spec.data | map(.secretKey + \"=\" + .remoteRef.key + \"#\" + .remoteRef.property) | join(\",\")" \
  client-secret=openchoreo/backstage-client-secret#value
assert_yq "$o" "$es | .spec.target.name" thunder-backstage-client
assert_yq "$o" 'select(.kind=="Job") | .spec.template.spec.containers[0].env[] | select(.name=="BACKSTAGE_CLIENT_SECRET") | .valueFrom.secretKeyRef.name + "/" + .valueFrom.secretKeyRef.key' \
  thunder-backstage-client/client-secret
grep -q backstage-portal-secret "$o" && fail "upstream literal Backstage client secret still rendered"
# no config = no render (else the Job would wait forever on a Secret nobody creates)
assert_fails helm template thunder $charts/thunder -n thunder -f $a/values.yaml --set backstageClientSecret=null
err=$(helm template thunder $charts/thunder -n thunder -f $a/values.yaml --set backstageClientSecret=null 2>&1 || true)
grep -q 'backstageClientSecret is required' <<<"$err" || fail "missing backstageClientSecret: render fails for another reason: $err"

# seed data (bootstrap scripts run by the setup Job; every script is check-then-create/update, so re-runs are safe)
scripts=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-bootstrap") | .data' "$o")
[ -n "$scripts" ] || fail "no thunder-bootstrap ConfigMap"
users=$(yq '.["50-user-schema-and-users.sh"]' <<<"$scripts")
# group names are what OpenChoreo's authz bootstrap mappings (and later Argo CD/Kargo RBAC) bind
got=$(grep -oE '^ *ensure_group +"[^"]+"' <<<"$users" | awk -F'"' '{print $2}' | sort | paste -sd, -)
[ "$got" = admins,developers,platform-engineers,sres ] || fail "groups = '$got'"
# OAuth apps: every APP_PAYLOAD is valid JSON; only the clients the lab uses (upstream's service clients have
# well-known secrets, service_mcp_client even maps to OpenChoreo admin - add them back with the feature that needs them)
payloads=$tmp/payloads.json
for k in $(yq 'keys | .[]' <<<"$scripts"); do
  yq ".[\"$k\"]" <<<"$scripts" >"$tmp/$k"
  if command -v shellcheck >/dev/null; then shellcheck -s bash "$tmp/$k" || fail "shellcheck $k"; fi
  # '"${VAR}"' = the script splices an env var into the single-quoted payload: validate it as a string
  awk "/APP_PAYLOAD='/ {f=1; sub(/.*APP_PAYLOAD='/, \"\")} f && /^ *}'\$/ {print \"}\"; f=0; next} f" "$tmp/$k" |
    sed -E "s/'\"\\$\\{([A-Z_]+)\\}\"'/env:\\1/g" | jq -c . >>"$payloads" || fail "$k: APP_PAYLOAD is not valid JSON"
done
app() { jq -c --arg c "$1" '.inbound_auth_config[].config | select(.client_id == $c)' "$payloads"; }
got=$(jq -r '.inbound_auth_config[].config.client_id' "$payloads" | sort | paste -sd, -)
[ "$got" = argocd,kargo,openchoreo-backstage-client,openchoreo-cli ] || fail "OAuth clients = '$got'"
[ "$(app openchoreo-backstage-client | jq -r '.redirect_uris | join(",")')" = \
  http://openchoreo.localhost:8080/api/auth/openchoreo-auth/handler/frame ] || fail "backstage redirect_uris"
# Backstage script with stubbed curl/log_*: it registers exactly $BACKSTAGE_CLIENT_SECRET and refuses to run without it
b=$tmp/51-backstage-app.sh
backstage() {   # backstage <secret> -> the JSON body the script POSTs
  BACKSTAGE_CLIENT_SECRET=$1 bash -c '
    set -e
    log_info() { :; }; log_error() { :; }
    curl() { while [ $# -gt 0 ]; do [ "$1" = --data ] && { printf "%s" "$2" >"$OUT"; shift; }; shift; done; echo "{}"; }
    source "$0"' "$b"
}
OUT=$tmp/posted.json; export OUT
backstage Abc123xyz >/dev/null || fail "51-backstage-app.sh failed with a secret set"
[ "$(jq -r '.inbound_auth_config[0].config | .client_id + ":" + .client_secret' "$OUT")" = openchoreo-backstage-client:Abc123xyz ] ||
  fail "51-backstage-app.sh posts '$(jq -c '.inbound_auth_config[0].config.client_secret' "$OUT")', want the env secret"
rm -f "$OUT"
assert_fails backstage ""
[ ! -e "$OUT" ] || fail "51-backstage-app.sh posted without a secret"
# Argo CD / Kargo (#19): public PKCE clients, no secret anywhere; groups + email in the ID token
# (redirect URIs: test_sso_oidc.sh, against the Argo CD / Kargo configs)
for c in argocd kargo; do
  j=$(app "$c")
  [ "$(jq -c '[.public_client, .pkce_required, .token_endpoint_auth_method, has("client_secret")]' <<<"$j")" = '[true,true,"none",false]' ] ||
    fail "$c: not a public PKCE client"
  [ "$(jq -c '[.token.id_token.user_attributes | index("groups", "email") != null] | all' <<<"$j")" = true ] ||
    fail "$c: id_token lacks groups/email"
  [ "$(jq -c '.scope_claims.groups' <<<"$j")" = '["groups"]' ] || fail "$c: no groups scope claim"
done

