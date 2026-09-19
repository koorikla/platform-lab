#!/usr/bin/env bash
# Thunder IdP on the hub (upstream OpenChoreo 1.2.5 k3d values). Its PVC hook also needs the argocd-cm PVC health
# override (test_argocd_pvc_health.sh); its Backstage client secret comes from OpenBao (#9 contract).
# Deployment, route, config, hooks and the client-secret wiring: thunder chart unit tests
# (repos/platform-charts/thunder/tests/). Here: the addon and pin, and the bootstrap scripts the setup Job runs.
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/thunder
assert_yq $a/addon.yaml '.addon.namespace' thunder
assert_yq $a/addon.yaml '.addon.releaseName' thunder
assert_yq $charts/thunder/Chart.yaml '.dependencies[] | select(.name=="thunder") | .repository + ":" + .version' \
  oci://ghcr.io/asgardeo/helm-charts:0.28.0   # = THUNDER_VERSION in upstream install/k3d/k3d-install.sh @ v1.2.5
o=$(render thunder $charts/thunder -n thunder -f $a/values.yaml)
# anywhere in the render (upstream's bootstrap scripts carried it)
grep -q backstage-portal-secret "$o" && fail "upstream literal Backstage client secret still rendered"

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

