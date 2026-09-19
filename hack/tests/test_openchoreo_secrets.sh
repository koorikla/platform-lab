#!/usr/bin/env bash
# #9: OpenChoreo's secrets in OpenBao + hub ClusterSecretStore `default`.
# Values are generated once in-cluster (ESO Password, CreatedOnce) into Secret openbao/openchoreo-generated (source of
# truth: it outlives OpenBao's in-memory dev mode) and pushed to secret/openchoreo/<key> through a seeder store. The
# `default` store reads that prefix only, from the OpenChoreo namespaces only. Every path the PushSecret and the
# backstage-secrets ExternalSecret touch must be granted by the matching policy that server.postStart writes.
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
post=$(yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].lifecycle.postStart.exec.command[2]' "$o")
keys=backstage-backend-secret,backstage-client-secret,backstage-jenkins-api-key

# --- no literal secret values in git: postStart seeds config only, never KV data
! grep -qE 'kv put|kv patch|/v1/secret/data' <<<"$post" || fail "postStart writes KV data (values belong in the generator)"

# --- source of truth: generated once, never rotated by a refresh
gen='select(.kind=="Password" and .metadata.name=="openchoreo-generated")'
assert_yq "$o" "$gen | .apiVersion" generators.external-secrets.io/v1alpha1
assert_yq "$o" "$gen | .metadata.namespace" openbao
assert_yq "$o" "$gen | .spec.secretKeys | sort | join(\",\")" "$keys"
assert_yq "$o" "$gen | .spec.length >= 32" true
assert_yq "$o" "$gen | .spec.symbols" 0          # OAuth client secret goes into forms/headers/JSON as is
src='select(.kind=="ExternalSecret" and .metadata.name=="openchoreo-generated")'
assert_yq "$o" "$src | .metadata.namespace" openbao
assert_yq "$o" "$src | .spec.refreshPolicy" CreatedOnce
assert_yq "$o" "$src | .spec.target.name" openchoreo-generated
assert_yq "$o" "$src | .spec.dataFrom[0].sourceRef.generatorRef | .apiVersion + \"/\" + .kind + \"/\" + .name" \
  generators.external-secrets.io/v1alpha1/Password/openchoreo-generated

# --- seeding: the k8s Secret -> secret/openchoreo/<key> (property value), re-pushed after an OpenBao restart
ps='select(.kind=="PushSecret" and .metadata.name=="openchoreo-generated")'
assert_yq "$o" "$ps | .metadata.namespace" openbao
assert_yq "$o" "$ps | .spec.selector.secret.name" openchoreo-generated
assert_yq "$o" "$ps | .spec.refreshInterval" 1m
# same chart as OpenBao: a Delete finalizer could never reach a server that is being removed with it
assert_yq "$o" "$ps | .spec.deletionPolicy" None
assert_yq "$o" "$ps | .spec.secretStoreRefs | map(.kind + \"/\" + .name) | join(\",\")" SecretStore/openchoreo-seeder
assert_yq "$o" "$ps | [.spec.data[] | .match.secretKey] | sort | join(\",\")" "$keys"
assert_yq "$o" "$ps | [.spec.data[] | select(.match.remoteRef.remoteKey != \"openchoreo/\" + .match.secretKey or .match.remoteRef.property != \"value\")] | length" 0
seed='select(.kind=="SecretStore" and .metadata.name=="openchoreo-seeder")'
assert_yq "$o" "$seed | .metadata.namespace" openbao
assert_yq "$o" "$seed | .spec.provider.vault | .server + \" \" + .path + \" \" + .version" "http://openbao.openbao.svc:8200 secret v2"
assert_yq "$o" "$seed | .spec.provider.vault.auth.kubernetes | .mountPath + \" \" + .role + \" \" + .serviceAccountRef.name" \
  "kubernetes openchoreo-seeder openbao-openchoreo-seeder"

# --- ClusterSecretStore default (the name OpenChoreo expects): read-only, OpenChoreo namespaces only
css='select(.kind=="ClusterSecretStore" and .metadata.name=="default")'
assert_yq "$o" "[$css] | length" 1
assert_yq "$o" "$css | .spec.provider.vault | .server + \" \" + .path + \" \" + .version" "http://openbao.openbao.svc:8200 secret v2"
assert_yq "$o" "$css | .spec.provider.vault.auth.kubernetes | .mountPath + \" \" + .role + \" \" + .serviceAccountRef.name + \"/\" + .serviceAccountRef.namespace" \
  "kubernetes openchoreo-reader openbao-openchoreo-reader/openbao"
# openchoreo-control-plane: backstage-secrets; thunder: the Backstage app's client secret (#10 contract, see chart values)
assert_yq "$o" "$css | .spec.conditions[0].namespaces | sort | join(\",\")" openchoreo-control-plane,thunder
for sa in openbao-openchoreo-reader openbao-openchoreo-seeder; do
  assert_yq "$o" "[select(.kind==\"ServiceAccount\" and .metadata.name==\"$sa\" and .metadata.namespace==\"openbao\")] | length" 1
done

# --- OpenBao roles: each bound to exactly its store's ServiceAccount in the openbao namespace
role() { grep -A1 "auth/kubernetes/role/$1 " <<<"$post" | tr -d '\\\n' | tr -s ' '; }
for r in openchoreo-reader:openbao-openchoreo-reader openchoreo-seeder:openbao-openchoreo-seeder; do
  line=$(role "${r%%:*}"); [ -n "$line" ] || fail "postStart: no role ${r%%:*}"
  grep -q "token_policies=${r%%:*} " <<<"$line" || fail "role ${r%%:*}: token_policies must be exactly ${r%%:*}: $line"
  grep -q "bound_service_account_names=${r#*:} " <<<"$line" || fail "role ${r%%:*}: must bind SA ${r#*:}: $line"
  grep -q 'bound_service_account_namespaces="$BAO_K8S_NAMESPACE"' <<<"$line" || fail "role ${r%%:*}: must bind the openbao namespace only: $line"
done

# --- policy coverage. caps <policy> <path>: capabilities of the policy paths matching <path> (vault: trailing * = prefix)
policy() { awk -v p="bao policy write $1 -" 'index($0, p) {f=1; next} /^ *EOP/ {f=0} f' <<<"$post"; }
caps() {
  local line p out=""
  while read -r line; do
    p=$(sed -n 's/^ *path "\([^"]*\)".*/\1/p' <<<"$line"); [ -n "$p" ] || continue
    # shellcheck disable=SC2053  # glob match on purpose
    [[ "$2" == ${p//+/[!\/]*} ]] && out+=$(sed -n 's/.*capabilities = \[\([^]]*\)\].*/\1/p' <<<"$line" | tr -d '" ')","
  done <<<"$(policy "$1")"
  echo "$out"
}
need() {  # need <policy> <path> <cap...>
  local c got; got=$(caps "$1" "$2")
  for c in "${@:3}"; do [[ ",$got" == *",$c,"* ]] || fail "policy $1: no '$c' on $2 (has '$got')"; done
}
[ -n "$(policy openchoreo-reader)" ] || fail "postStart: no policy openchoreo-reader"
[ -n "$(policy openchoreo-seeder)" ] || fail "postStart: no policy openchoreo-seeder"
for k in ${keys//,/ }; do
  # ESO vault v2 PushSecret: reads data + metadata (managed-by check, CAS version), writes both
  need openchoreo-seeder "secret/data/openchoreo/$k" create read update
  need openchoreo-seeder "secret/metadata/openchoreo/$k" create read update
  need openchoreo-reader "secret/data/openchoreo/$k" read
done
# least privilege: the reader never writes; neither role reaches beyond secret/openchoreo/
reader=$(policy openchoreo-reader)
! grep -qE 'create|update|delete|sudo' <<<"$reader" || fail "openchoreo-reader must be read-only: $reader"
for p in secret/data/clusters/dev1/argocd-agent secret/data/other sys/policies/acl/x auth/kubernetes/role/x; do
  [ -z "$(caps openchoreo-reader $p)$(caps openchoreo-seeder $p)" ] || fail "openchoreo policies reach $p"
done

# --- consumer: the control-plane umbrella's backstage-secrets ExternalSecret, from the store above, keys it pushes
c=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n openchoreo-control-plane \
  -f $config/addons/management/openchoreo-control-plane/values.yaml)
want=$(yq '.openchoreo-control-plane.backstage.secretName' $charts/openchoreo-control-plane/values.yaml)
bs="select(.kind==\"ExternalSecret\" and .spec.target.name==\"$want\")"
assert_yq "$c" "[$bs] | length" 1
assert_yq "$c" "$bs | .metadata.namespace" openchoreo-control-plane
assert_yq "$c" "$bs | .spec.secretStoreRef | .kind + \"/\" + .name" ClusterSecretStore/default
# chart templates/backstage/deployment.yaml: these three are mandatory (jenkins-api-key too, no `optional`)
assert_yq "$c" "$bs | [.spec.data[] | .secretKey] | sort | join(\",\")" backend-secret,client-secret,jenkins-api-key
assert_yq "$c" "$bs | [.spec.data[] | .secretKey + \"<-\" + .remoteRef.key + \"/\" + .remoteRef.property] | sort | join(\",\")" \
  "backend-secret<-openchoreo/backstage-backend-secret/value,client-secret<-openchoreo/backstage-client-secret/value,jenkins-api-key<-openchoreo/backstage-jenkins-api-key/value"
ns=$(yq "$bs | .metadata.namespace" "$c")
assert_yq "$o" "$css | .spec.conditions[0].namespaces | contains([\"$ns\"])" true
