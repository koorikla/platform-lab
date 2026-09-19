#!/usr/bin/env bash
# #40: SecretStore argocd/in-cluster (SA eso-in-cluster) may `get` exactly the Secrets its ExternalSecrets read, never
# the whole argocd namespace. Ownership: the principal chart owns SA + store + the JWT rule; the cluster chart adds one
# Role/RoleBinding per worker. Each chart's rules: its unit tests (argocd-agent-principal/tests/in_cluster_store_test.yaml,
# cluster/tests/argocd_identity_test.yaml). Here: the two charts agree, for every real worker file.
source "$(dirname "$0")/lib.sh"

# rules on secrets of the store SA's Roles (named eso-in-cluster*), and every binding of that SA in a render
secret_rules='[select(.kind=="Role" and (.metadata.name | test("^eso-in-cluster"))) | .rules[] | select(.resources[] == "secrets")]'
sa_bindings='[select((.kind=="RoleBinding" or .kind=="ClusterRoleBinding") and ([.subjects[] | select(.name=="eso-in-cluster")] | length > 0))]'
# every remoteRef.key read through the in-cluster store, and every name the store's SA may get
es_keys='[select(.kind=="ExternalSecret" and .spec.secretStoreRef.name=="in-cluster") | .spec.data[].remoteRef.key] | unique | sort | join(",")'
granted="$secret_rules | [.[].resourceNames[]] | unique | sort | join(\",\")"

# --- principal (hub values): the store, its SA, and exactly the grants its own ExternalSecrets need
p=$(render argocd-agent $charts/argocd-agent-principal -n argocd -f $config/addons/management/argocd-agent-principal/values.yaml)
store_sa=$(yq 'select(.kind=="SecretStore" and .metadata.name=="in-cluster") | .spec.provider.kubernetes.auth.serviceAccount.name' "$p")
assert_yq "$p" "[select(.kind==\"ServiceAccount\" and .metadata.name==\"$store_sa\")] | length" 1
assert_yq "$p" "$granted" "$(yq eval-all "$es_keys" "$p")"
# the cluster chart's values name the same store and SA
assert_yq $charts/cluster/values.yaml '.inClusterStore.name + "/" + .inClusterStore.serviceAccount' "in-cluster/$store_sa"

# --- every worker file (enabled or not): reads through the store exactly what it grants, bound to the principal's SA
n=0
for f in $config/fleet/clusters/*/*.yaml*; do
  [ "$(yq '.role // "worker"' "$f")" = worker ] || continue
  c=$(yq '.name' "$f"); n=$((n + 1))
  w=$(render "$c" $charts/cluster -f "$f")
  assert_yq "$w" "$es_keys" "$c-agent-client-tls"
  assert_yq "$w" "$granted" "$c-agent-client-tls"
  assert_yq "$w" "$sa_bindings | length" 1
  assert_yq "$w" "$sa_bindings | .[0] | .kind + \"/\" + .metadata.namespace + \"/\" + .roleRef.name + \" -> \" + .subjects[0].namespace + \"/\" + .subjects[0].name" \
    "RoleBinding/argocd/eso-in-cluster-$c -> argocd/$store_sa"
done
[ "$n" -ge 2 ] || fail "expected several worker cluster files, found $n"
