#!/usr/bin/env bash
# Argo CD and Kargo log in via Thunder (#19): public OIDC clients with PKCE (no client secret anywhere), Thunder groups
# mapped to roles, local admin kept as break-glass. Facts checked at argo-helm 10.9.2 (Argo CD v3.5.3) / kargo 1.11.4.
source "$(dirname "$0")/lib.sh"
t=$(render thunder $charts/thunder -n thunder -f $config/addons/management/thunder/values.yaml)
thunder_cfg=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-config-map") | .data["deployment.yaml"]' "$t")
issuer=$(yq '.server.public_url' <<<"$thunder_cfg")   # Thunder's iss = publicUrl (jwt.issuer empty)
[ "$issuer" = http://thunder.openchoreo.localhost:8080 ] || fail "Thunder issuer = '$issuer'"
payloads=$tmp/payloads.json
yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-bootstrap") | .data | to_entries | .[] | .value' "$t" |
  awk "/APP_PAYLOAD='/ {f=1; sub(/.*APP_PAYLOAD='/, \"\")} f && /^ *}'\$/ {print \"}\"; f=0; next} f" |
  sed -E "s/'\"\\$\\{([A-Z_]+)\\}\"'/env:\\1/g" | jq -c . >"$payloads" || fail "Thunder APP_PAYLOADs are not valid JSON"
client() { jq -c --arg c "$1" '.inbound_auth_config[].config | select(.client_id == $c)' "$payloads"; }
redirects() { client "$1" | jq -r '.redirect_uris | sort | join(",")'; }

# --- Argo CD ---------------------------------------------------------------------------------------------------------
a=$(render argocd $charts/argo-cd -n argocd -f $config/addons/management/argo-cd/values.yaml)
cm='select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data'
url=$(yq "$cm | .url" "$a")
[ "$url" = http://localhost:8090 ] || fail "argocd-cm url = '$url', want the make-ui port-forward"
# browsers reach both UIs only through `make ui`: redirect URIs are worthless on any other port
ui=$(make -s -n ui)
grep -qF -- 'svc/argocd-server 8090:' <<<"$ui" || fail "make ui: Argo CD not on 8090 (argocd-cm url)"
grep -qF -- 'svc/kargo-api 8091:' <<<"$ui" || fail "make ui: Kargo not on 8091 (Thunder kargo redirect/CORS)"
assert_yq "$a" "$cm | .[\"admin.enabled\"]" true      # break-glass: local admin stays
oidc=$(yq "$cm | .[\"oidc.config\"]" "$a")
assert_yq - '.issuer' "$issuer" <<<"$oidc"            # go-oidc: must equal the discovery issuer byte for byte
assert_yq - '.clientID' argocd <<<"$oidc"
assert_yq - '.enablePKCEAuthentication' true <<<"$oidc"
assert_yq - 'has("clientSecret") or has("cliClientID")' false <<<"$oidc"
assert_yq - '.requestedScopes | join(",")' openid,profile,email,groups <<<"$oidc"   # Thunder emits groups only on scope groups
# v3.5.3 PKCE runs server-side (util/oidc/oidc.go): redirect = url + /auth/callback (common.CallbackEndpoint);
# the docs' /pkce/verify is a leftover of the old browser flow. CLI: argocd login --sso, default --sso-port 8085.
[ "$(redirects argocd)" = "http://localhost:8085/auth/callback,$url/auth/callback" ] ||
  fail "Thunder argocd redirect_uris = '$(redirects argocd)'"
rbac='select(.kind=="ConfigMap" and .metadata.name=="argocd-rbac-cm") | .data'
assert_yq "$a" "$rbac | .scopes" '[groups]'
assert_yq "$a" "$rbac | .[\"policy.default\"] // \"\"" ''   # authenticated but in no mapped group = no access
if command -v argocd >/dev/null; then
  pol=$tmp/argocd-rbac-cm.yaml; yq "select(.kind==\"ConfigMap\" and .metadata.name==\"argocd-rbac-cm\")" "$a" >"$pol"
  can() {   # can <subject> <action> <resource> <object> -> Yes/No (exit code 1 on No)
    { argocd admin settings rbac can "$1" "$2" "$3" "$4" --policy-file "$pol" 2>/dev/null || true; } | tail -1
  }
  while read -r want sub act res obj; do
    got=$(can "$sub" "$act" "$res" "$obj")
    [ "$got" = "$want" ] || fail "rbac: $sub $act $res $obj = '$got', want $want"
  done <<'EOF'
Yes admin update clusters x
Yes admins update clusters x
Yes admins create exec p/a
Yes platform-engineers sync applications p/a
Yes platform-engineers delete applications p/a
Yes platform-engineers create applicationsets p/a
Yes platform-engineers get clusters x
No platform-engineers update clusters x
No platform-engineers update projects x
No platform-engineers update repositories x
No platform-engineers update accounts x
No platform-engineers create exec p/a
Yes developers get applications p/a
Yes developers get logs p/a
No developers sync applications p/a
Yes sres get applications p/a
No sres sync applications p/a
No someone-else get applications p/a
EOF
else
  echo "skip: argocd CLI not on PATH (RBAC not evaluated)"
fi

# --- Kargo -----------------------------------------------------------------------------------------------------------
k=$(render kargo $charts/kargo -n kargo -f $config/addons/management/kargo/values.yaml)
env='select(.kind=="ConfigMap" and .metadata.name=="kargo-api") | .data'
assert_yq "$k" "$env | .OIDC_ENABLED" true
assert_yq "$k" "$env | .OIDC_ISSUER_URL" "$issuer"
assert_yq "$k" "$env | .OIDC_CLIENT_ID" kargo              # not api.host: that is only the bundled-Dex client id
assert_yq "$k" "$env | .OIDC_CLI_CLIENT_ID" null
assert_yq "$k" "$env | .OIDC_ADDITIONAL_SCOPES" groups     # openid, profile, email are always requested
assert_yq "$k" "$env | .OIDC_USERNAME_CLAIM" email
assert_yq "$k" "$env | .ADMIN_ACCOUNT_ENABLED" true        # break-glass: local admin stays
assert_yq "$k" '[select(.kind=="Deployment" and .metadata.name=="kargo-dex-server")] | length' 0
# Kargo UI does PKCE in the browser: redirect = UI origin + /login, and Thunder must allow that origin (CORS)
[ "$(redirects kargo)" = http://localhost:8091/login ] || fail "Thunder kargo redirect_uris = '$(redirects kargo)'"
yq '.cors.allowed_origins[]' <<<"$thunder_cfg" | grep -qx http://localhost:8091 || fail "Thunder CORS lacks the Kargo UI"
claims() { yq "select(.kind==\"ServiceAccount\" and .metadata.name==\"$1\") | .metadata.annotations[\"rbac.kargo.akuity.io/claims\"]" "$k"; }
[ "$(claims kargo-admin)" = '{"groups":["admins","platform-engineers"]}' ] || fail "kargo-admin claims = '$(claims kargo-admin)'"
[ "$(claims kargo-viewer)" = '{"groups":["developers","sres"]}' ] || fail "kargo-viewer claims = '$(claims kargo-viewer)'"
for sa in kargo-user kargo-project-creator; do [ "$(claims $sa)" = null ] || fail "$sa claims = '$(claims $sa)', want none"; done

# every group mapped above exists in Thunder (a typo would silently grant nothing)
users=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="thunder-bootstrap") | .data["50-user-schema-and-users.sh"]' "$t")
for g in admins platform-engineers developers sres; do
  grep -qE "^ *ensure_group +\"$g\"" <<<"$users" || fail "Thunder has no group $g"
done
