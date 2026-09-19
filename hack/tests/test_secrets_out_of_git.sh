#!/usr/bin/env bash
# #21: no admin/signing key material in git. Kargo's admin hash + token signing key come from an ESO Password generator
# (generated once in-cluster); the argocd-agent principal's JWT key is an RSA PKCS#8 key minted by cert-manager.
source "$(dirname "$0")/lib.sh"

# --- no literals in git (umbrella defaults and hub overrides alike)
for f in $charts/kargo/values.yaml $config/addons/management/kargo/values.yaml; do
  assert_yq "$f" '.kargo.api.adminAccount.passwordHash // "unset"' unset
  assert_yq "$f" '.kargo.api.adminAccount.tokenSigningKey // "unset"' unset
done
! git grep -qE '\$2[aby]?\$[0-9]{2}\$' -- repos || fail "bcrypt hash literal in repos/"
! git grep -q 'lab-only-change-me' -- repos || fail "token signing key literal in repos/"

# --- Kargo: api reads an ESO-generated Secret instead of the chart's kargo-api Secret
k=$(render kargo $charts/kargo -n kargo -f $config/addons/management/kargo/values.yaml)
assert_yq "$k" '[select(.kind=="Secret" and .metadata.name=="kargo-api")] | length' 0
sec=$(yq 'select(.kind=="Deployment" and .metadata.name=="kargo-api") | .spec.template.spec.containers[] | select(.name=="api")
  | .envFrom[] | select(.secretRef) | .secretRef.name' "$k")
[ "$sec" = kargo-api-admin ] || fail "kargo-api envFrom secret = '$sec', want kargo-api-admin"
# generator: two independent random values, no symbols (safe to paste into a shell / login form)
assert_yq "$k" 'select(.kind=="Password") | .apiVersion' generators.external-secrets.io/v1alpha1
assert_yq "$k" 'select(.kind=="Password") | .spec.secretKeys | sort | join(",")' password,signingKey
assert_yq "$k" 'select(.kind=="Password") | .spec.length >= 32' true
assert_yq "$k" 'select(.kind=="Password") | .spec.symbols' 0
gen=$(yq 'select(.kind=="Password") | .metadata.name' "$k")
es='select(.kind=="ExternalSecret" and .spec.target.name=="kargo-api-admin")'
assert_yq "$k" "[$es] | length" 1
# generated once: a refresh must never rotate the password under a running kargo-api
assert_yq "$k" "$es | .spec.refreshPolicy" CreatedOnce
assert_yq "$k" "$es | .spec.dataFrom[0].sourceRef.generatorRef | .apiVersion + \"/\" + .kind + \"/\" + .name" \
  "generators.external-secrets.io/v1alpha1/Password/$gen"
# exact env var names kargo-api expects (chart templates/api/secret.yaml); ESO templates survive helm escaping
assert_yq "$k" "$es | .spec.target.template.engineVersion" v2
assert_yq "$k" "$es | .spec.target.template.data.ADMIN_ACCOUNT_PASSWORD_HASH" '{{ .password | bcrypt }}'
assert_yq "$k" "$es | .spec.target.template.data.ADMIN_ACCOUNT_TOKEN_SIGNING_KEY" '{{ .signingKey }}'
# the operator can read the plaintext back (make kargo-password)
assert_yq "$k" "$es | .spec.target.template.data.adminPassword" '{{ .password }}'
grep -qE "^kargo-password:.*" Makefile || fail "Makefile: no kargo-password target"
grep -A2 '^kargo-password:' Makefile | grep -q 'secret kargo-api-admin .*adminPassword' || fail "kargo-password must read kargo-api-admin/adminPassword"

# --- argocd-agent principal: JWT key from a Secret, never self-generated
p=$(render argocd-agent $charts/argocd-agent-principal -n argocd -f $config/addons/management/argocd-agent-principal/values.yaml)
cm='select(.kind=="ConfigMap" and .metadata.name=="argocd-agent-principal-params")'
assert_yq "$p" "$cm | .data.\"principal.jwt.allow-generate\"" false
assert_yq "$p" "$cm | .data.\"principal.jwt.key-path\"" ''
assert_yq "$p" "$cm | .data.\"principal.jwt.secret-name\"" argocd-agent-jwt
# no config checksum in the chart: the pod template must change with the key source, or the old pod keeps its key
assert_yq "$p" 'select(.kind=="Deployment" and .metadata.name=="argocd-agent-principal") | .spec.template.metadata.annotations."platform.lab/jwt-key"' \
  secret/argocd-agent-jwt
# principal parses jwt.key with x509.ParsePKCS8PrivateKey and signs RS512 -> RSA in PKCS#8; the key must survive renewals
crt='select(.kind=="Certificate" and .metadata.name=="argocd-agent-jwt-key")'
assert_yq "$p" "$crt | .spec.privateKey | .algorithm + \"/\" + (.size|tostring) + \"/\" + .encoding + \"/\" + .rotationPolicy" \
  RSA/4096/PKCS8/Never
src=$(yq "$crt | .spec.secretName" "$p")
[ -n "$src" ] && [ "$src" != argocd-agent-jwt ] || fail "jwt Certificate must write its own Secret, got '$src'"
# ... copied tls.key -> argocd-agent-jwt/jwt.key through the existing in-cluster SecretStore
jes='select(.kind=="ExternalSecret" and .spec.target.name=="argocd-agent-jwt")'
assert_yq "$p" "[$jes] | length" 1
assert_yq "$p" "$jes | .spec.secretStoreRef | .kind + \"/\" + .name" SecretStore/in-cluster
assert_yq "$p" "$jes | .spec.data | length" 1
assert_yq "$p" "$jes | .spec.data[0] | .secretKey + \"<-\" + .remoteRef.key + \"/\" + .remoteRef.property" "jwt.key<-$src/tls.key"
