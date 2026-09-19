#!/usr/bin/env bash
# Thunder IdP on the hub (upstream OpenChoreo 1.2.5 k3d values) + the Argo CD health override its PVC hook needs
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
# browser-side token exchange (PKCE) needs CORS for Backstage + the Argo CD/Kargo UI ports of `make ui` (#19)
assert_yq - '.cors.allowed_origins | sort | join(",")' \
  http://localhost:7007,http://localhost:8090,http://localhost:8091,http://openchoreo.localhost:8080 <<<"$cfg"

# Helm hooks become Argo sync hooks. Exactly these, and the PVC must survive every sync after the first:
# hook-failed -> HookFailed instead of the default BeforeHookCreation (which deletes the in-use PVC).
# No DB-credentials Secret hook: sqlite has no password.
hooks='ConfigMap/thunder-bootstrap:pre-install:,ConfigMap/thunder-setup-config-map:pre-install:,Job/thunder-setup:pre-install:hook-succeeded,PersistentVolumeClaim/thunder-database-pvc:pre-install:hook-failed,ServiceAccount/thunder-service-account:pre-install:'
assert_yq "$o" '[select(.metadata.annotations["helm.sh/hook"] != null) | .kind + "/" + .metadata.name + ":" + .metadata.annotations["helm.sh/hook"] + ":" + (.metadata.annotations["helm.sh/hook-delete-policy"] // "")] | sort | join(",")' "$hooks"
assert_yq "$o" '[select(.metadata.annotations["argocd.argoproj.io/hook"] != null)] | length' 0
# the setup Job is the PVC's first consumer (local-path is WaitForFirstConsumer), so it must mount it
assert_yq "$o" 'select(.kind=="Job") | .spec.template.spec.volumes[] | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName' thunder-database-pvc

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
  awk "/APP_PAYLOAD='/ {f=1; sub(/.*APP_PAYLOAD='/, \"\")} f && /^ *}'\$/ {print \"}\"; f=0; next} f" "$tmp/$k" |
    jq -c . >>"$payloads" || fail "$k: APP_PAYLOAD is not valid JSON"
done
app() { jq -c --arg c "$1" '.inbound_auth_config[].config | select(.client_id == $c)' "$payloads"; }
got=$(jq -r '.inbound_auth_config[].config.client_id' "$payloads" | sort | paste -sd, -)
[ "$got" = argocd,kargo,openchoreo-backstage-client,openchoreo-cli ] || fail "OAuth clients = '$got'"
# Backstage: upstream literal secret (backstage-secrets client-secret must match, see values.yaml LAB ONLY)
[ "$(app openchoreo-backstage-client | jq -r '.redirect_uris | join(",")')" = \
  http://openchoreo.localhost:8080/api/auth/openchoreo-auth/handler/frame ] || fail "backstage redirect_uris"
# Argo CD / Kargo (#19): public PKCE clients, no secret anywhere; groups + email in the ID token
for c in argocd:http://localhost:8090/pkce/verify kargo:http://localhost:8091/login; do
  j=$(app "${c%%:*}")
  [ "$(jq -r '.redirect_uris | join(",")' <<<"$j")" = "${c#*:}" ] || fail "${c%%:*} redirect_uris"
  [ "$(jq -c '[.public_client, .pkce_required, .token_endpoint_auth_method, has("client_secret")]' <<<"$j")" = '[true,true,"none",false]' ] ||
    fail "${c%%:*}: not a public PKCE client"
  [ "$(jq -c '[.token.id_token.user_attributes | index("groups", "email") != null] | all' <<<"$j")" = true ] ||
    fail "${c%%:*}: id_token lacks groups/email"
  [ "$(jq -c '.scope_claims.groups' <<<"$j")" = '["groups"]' ] || fail "${c%%:*}: no groups scope claim"
done

# Argo CD (hub umbrella): a Pending Helm-hook PVC is Healthy, so PreSync reaches the Job that binds it
h=$(render argocd $charts/argo-cd -n argocd -f $config/addons/management/argo-cd/values.yaml)
lua=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data["resource.customizations.health.PersistentVolumeClaim"]' "$h")
grep -q 'helm.sh/hook' <<<"$lua" || fail "argocd-cm: no PVC health override for Helm hooks"
# evaluate the Lua with the real Argo CD code when the CLI is around (CI may not have it)
if command -v argocd >/dev/null; then
  cm=$tmp/argocd-cm.yaml; yq 'select(.kind=="ConfigMap" and .metadata.name=="argocd-cm")' "$h" >"$cm"
  pvc() {   # pvc <phase> <hook annotation or ""> -> STATUS reported by argocd admin
    local f; f=$(mktemp "$tmp/pvc.XXXXXX")
    yq -n ".apiVersion=\"v1\" | .kind=\"PersistentVolumeClaim\" | .metadata.name=\"p\" | .status.phase=\"$1\"" >"$f"
    [ -z "$2" ] || yq -i ".metadata.annotations[\"helm.sh/hook\"]=\"$2\"" "$f"
    argocd admin settings resource-overrides health "$f" --argocd-cm-path "$cm" 2>&1 | awk '/^STATUS:/ {print $2}'
  }
  [ "$(pvc Pending pre-install)" = Healthy ] || fail "hook PVC Pending: $(pvc Pending pre-install), want Healthy"
  [ "$(pvc Pending "")" = Progressing ] || fail "plain PVC Pending: $(pvc Pending ""), want Progressing"
  [ "$(pvc Bound "")" = Healthy ] || fail "PVC Bound: $(pvc Bound ""), want Healthy"
  [ "$(pvc Lost "")" = Degraded ] || fail "PVC Lost: $(pvc Lost ""), want Degraded"
fi
