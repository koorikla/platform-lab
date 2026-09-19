#!/usr/bin/env bash
# #21: no admin/signing key material in git. Kargo's admin hash + token signing key come from an ESO Password generator
# (generated once in-cluster); the argocd-agent principal's JWT key is an RSA PKCS#8 key minted by cert-manager. Both
# charts' generators, ExternalSecrets and wiring: their unit tests (kargo/tests/admin_secret_test.yaml,
# argocd-agent-principal/tests/jwt_key_test.yaml). Here: no literal anywhere in git, and the operator's way back in.
source "$(dirname "$0")/lib.sh"

# --- no literals in git (umbrella defaults and hub overrides alike)
for f in $charts/kargo/values.yaml $config/addons/management/kargo/values.yaml; do
  assert_yq "$f" '.kargo.api.adminAccount.passwordHash // "unset"' unset
  assert_yq "$f" '.kargo.api.adminAccount.tokenSigningKey // "unset"' unset
done
! git grep -qE '\$2[aby]?\$[0-9]{2}\$' -- repos || fail "bcrypt hash literal in repos/"
! git grep -q 'lab-only-change-me' -- repos || fail "token signing key literal in repos/"

# --- with the hub's values, kargo-api still reads the generated Secret, and the operator can read the password back
k=$(render kargo $charts/kargo -n kargo -f $config/addons/management/kargo/values.yaml)
assert_yq "$k" '[select(.kind=="Secret" and .metadata.name=="kargo-api")] | length' 0
sec=$(yq 'select(.kind=="Deployment" and .metadata.name=="kargo-api") | .spec.template.spec.containers[] | select(.name=="api")
  | .envFrom[] | select(.secretRef) | .secretRef.name' "$k")
assert_yq "$k" "select(.kind==\"ExternalSecret\" and .spec.target.name==\"$sec\") | .spec.target.template.data | has(\"adminPassword\")" true
grep -qE "^kargo-password:.*" Makefile || fail "Makefile: no kargo-password target"
grep -A2 '^kargo-password:' Makefile | grep -q "secret $sec .*adminPassword" || fail "kargo-password must read $sec/adminPassword"
