#!/usr/bin/env bash
# #9: OpenChoreo's secrets in OpenBao + hub ClusterSecretStore `default`.
# Each value is generated once in-cluster (ESO Password, CreatedOnce) into its own Secret openbao/openchoreo-<key>
# (source of truth: OpenBao follows it, PushSecret every minute) and pushed to secret/openchoreo/<key> through a seeder
# store. The `default` store reads that prefix only, from the OpenChoreo namespaces only. The generators, Secrets,
# PushSecrets, stores and "no KV data in configure.sh": openbao chart unit tests (tests/openchoreo_test.yaml,
# tests/stores_test.yaml, tests/configure_test.yaml). Here: every path the PushSecrets and the backstage-secrets
# ExternalSecret touch is granted by the matching policy (ConfigMap openbao-configure, applied with the roles in its
# configure.sh by the configure sidecar), and the control plane consumes exactly what the openbao chart pushes.
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
conf='select(.kind=="ConfigMap" and .metadata.name=="openbao-configure") | .data'
post=$(yq "$conf | .[\"configure.sh\"]" "$o")
ps='select(.kind=="PushSecret" and (.metadata.name | test("^openchoreo-")))'
keys=$(yq eval-all "[$ps | .spec.data[].match.remoteRef.remoteKey | sub(\"^openchoreo/\", \"\")] | sort | join(\",\")" "$o")
[ "$keys" = backstage-backend-secret,backstage-client-secret,backstage-jenkins-api-key ] || fail "pushed keys: $keys"
css='select(.kind=="ClusterSecretStore" and .metadata.name=="default")'

# --- OpenBao roles: each bound to exactly its store's ServiceAccount in the openbao namespace
role() { grep -A1 "auth/kubernetes/role/$1 " <<<"$post" | tr -d '\\\n' | tr -s ' '; }
for r in openchoreo-reader:openbao-openchoreo-reader openchoreo-seeder:openbao-openchoreo-seeder; do
  line=$(role "${r%%:*}"); [ -n "$line" ] || fail "configure.sh: no role ${r%%:*}"
  grep -q "token_policies=${r%%:*} " <<<"$line" || fail "role ${r%%:*}: token_policies must be exactly ${r%%:*}: $line"
  grep -q "bound_service_account_names=${r#*:} " <<<"$line" || fail "role ${r%%:*}: must bind SA ${r#*:}: $line"
  grep -q 'bound_service_account_namespaces="$BAO_K8S_NAMESPACE"' <<<"$line" || fail "role ${r%%:*}: must bind the openbao namespace only: $line"
done
# ...and those are the roles/SAs the chart's stores log in with
assert_yq "$o" 'select(.kind=="SecretStore" and .metadata.name=="openchoreo-seeder") | .spec.provider.vault.auth.kubernetes | .role + "/" + .serviceAccountRef.name' \
  openchoreo-seeder/openbao-openchoreo-seeder
assert_yq "$o" "$css | .spec.provider.vault.auth.kubernetes | .role + \"/\" + .serviceAccountRef.name" \
  openchoreo-reader/openbao-openchoreo-reader

# --- policy coverage. caps <policy> <path>: capabilities of the policy paths matching <path> (vault: trailing * = prefix)
policy() { yq "$conf | .[\"$1.hcl\"] // \"\"" "$o" | grep -vE '^ *(#|$)' || true; }   # rules only, no comments
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
[ -n "$(policy openchoreo-reader)" ] || fail "ConfigMap openbao-configure: no policy openchoreo-reader"
[ -n "$(policy openchoreo-seeder)" ] || fail "ConfigMap openbao-configure: no policy openchoreo-seeder"
for k in ${keys//,/ }; do
  # ESO vault v2 PushSecret: reads data + metadata (managed-by check, CAS version), writes both
  need openchoreo-seeder "secret/data/openchoreo/$k" create read update
  need openchoreo-seeder "secret/metadata/openchoreo/$k" create read update
  need openchoreo-reader "secret/data/openchoreo/$k" read
done
# least privilege: the reader never writes; neither role reaches beyond secret/openchoreo/
reader=$(policy openchoreo-reader)
! grep -qE 'create|update|delete|sudo' <<<"$reader" || fail "openchoreo-reader must be read-only: $reader"
# deletionPolicy None -> ESO never deletes; delete on metadata/ would destroy every version
! grep -qE 'delete|sudo|list' <<<"$(policy openchoreo-seeder)" || fail "openchoreo-seeder: create/read/update only: $(policy openchoreo-seeder)"
for p in secret/data/clusters/dev1/argocd-agent secret/data/other sys/policies/acl/x auth/kubernetes/role/x; do
  [ -z "$(caps openchoreo-reader $p)$(caps openchoreo-seeder $p)" ] || fail "openchoreo policies reach $p"
done

# --- consumer: the control-plane umbrella's backstage-secrets ExternalSecret reads exactly the pushed keys and
#     property, through store default, from a namespace that store serves
c=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n openchoreo-control-plane \
  -f $config/addons/management/openchoreo-control-plane/values.yaml)
want=$(yq '.openchoreo-control-plane.backstage.secretName' $charts/openchoreo-control-plane/values.yaml)
bs="select(.kind==\"ExternalSecret\" and .spec.target.name==\"$want\")"
assert_yq "$c" "[$bs] | length" 1
assert_yq "$c" "$bs | [.spec.data[].remoteRef | .key + \"#\" + .property] | sort | join(\",\")" \
  "$(yq eval-all "[$ps | .spec.data[].match.remoteRef | .remoteKey + \"#\" + .property] | sort | join(\",\")" "$o")"
store=$(yq "$bs | .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name" "$c")
assert_yq "$o" "[select(.kind + \"/\" + .metadata.name == \"$store\")] | length" 1
ns=$(yq "$bs | .metadata.namespace" "$c")
assert_yq "$o" "select(.kind + \"/\" + .metadata.name == \"$store\") | .spec.conditions[0].namespaces | contains([\"$ns\"])" true
