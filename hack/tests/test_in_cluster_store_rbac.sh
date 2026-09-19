#!/usr/bin/env bash
# #40: SecretStore argocd/in-cluster (SA eso-in-cluster) may `get` exactly the Secrets its ExternalSecrets read, never
# the whole argocd namespace (agent CA key, JWT key, repo creds...). ESO's kubernetes provider (v2.10.0) reads a
# remoteRef with a single GET and validates the store with a SelfSubjectRulesReview (any get-on-secrets rule, even
# name-scoped, reports Ready), so: no list/watch, resourceNames everywhere.
# Ownership: the principal chart owns SA + store + the JWT rule; the cluster chart adds one Role/RoleBinding per worker.
source "$(dirname "$0")/lib.sh"

# Roles of the store's SA are named eso-in-cluster* (asserted below via each RoleBinding); their rules on secrets:
secret_rules='[select(.kind=="Role" and (.metadata.name | test("^eso-in-cluster"))) | .rules[] | select(.resources[] == "secrets")]'
# ... and nothing else in a render may bind that SA (a stray binding would bypass the name-scoped Roles)
sa_bindings='[select((.kind=="RoleBinding" or .kind=="ClusterRoleBinding") and ([.subjects[] | select(.name=="eso-in-cluster")] | length > 0))]'
# every remoteRef.key read through the in-cluster store, and every name the store's SA may get
es_keys='[select(.kind=="ExternalSecret" and .spec.secretStoreRef.name=="in-cluster") | .spec.data[].remoteRef.key] | unique | sort | join(",")'
granted="$secret_rules | [.[].resourceNames[]] | unique | sort | join(\",\")"

# --- principal: SA + store stay; its Role covers only the JWT key source
p=$(render argocd-agent $charts/argocd-agent-principal -n argocd -f $config/addons/management/argocd-agent-principal/values.yaml)
assert_yq "$p" 'select(.kind=="SecretStore" and .metadata.name=="in-cluster") | .spec.provider.kubernetes.auth.serviceAccount.name' eso-in-cluster
assert_yq "$p" '[select(.kind=="ServiceAccount" and .metadata.name=="eso-in-cluster")] | length' 1
role='select(.kind=="Role" and .metadata.name=="eso-in-cluster")'
assert_yq "$p" "$secret_rules | length" 1
assert_yq "$p" "$secret_rules | .[0].verbs | join(\",\")" get
assert_yq "$p" "$secret_rules | .[0].resourceNames | join(\",\")" argocd-agent-jwt-key
assert_yq "$p" "$es_keys" argocd-agent-jwt-key
assert_yq "$p" "$granted" argocd-agent-jwt-key
assert_yq "$p" "$role | .metadata.namespace" argocd
# no find/dataFrom through this store: that would need list
assert_yq "$p" '[select(.kind=="ExternalSecret" and .spec.secretStoreRef.name=="in-cluster") | .spec.dataFrom // [] | .[]] | length' 0
# store validation: SelfSubjectRulesReview (system:basic-user grants it too; explicit so the store never depends on it)
assert_yq "$p" "$role | [.rules[] | select(.resources[] == \"selfsubjectrulesreviews\") | .verbs[]] | join(\",\")" create
assert_yq "$p" "$sa_bindings | length" 1
assert_yq "$p" "$sa_bindings | .[0] | .kind + \"/\" + .roleRef.name + \" -> \" + .subjects[0].namespace + \"/\" + .subjects[0].name" \
  "RoleBinding/eso-in-cluster -> argocd/eso-in-cluster"
sa=$(yq 'select(.kind=="ServiceAccount" and .metadata.name=="eso-in-cluster") | .metadata.name' "$p")

# --- every worker file (enabled or not): its own client cert only, bound to the principal's SA
n=0
for f in $config/fleet/clusters/*/*.yaml*; do
  [ "$(yq '.role // "worker"' "$f")" = worker ] || continue
  c=$(yq '.name' "$f"); n=$((n + 1))
  w=$(render "$c" $charts/cluster -f "$f")
  assert_yq "$w" "$secret_rules | [.[] | select(.resourceNames == null)] | length" 0
  assert_yq "$w" "$secret_rules | [.[].verbs[]] | unique | join(\",\")" get
  assert_yq "$w" "$es_keys" "$c-agent-client-tls"
  assert_yq "$w" "$granted" "$c-agent-client-tls"
  assert_yq "$w" "[select(.kind==\"Role\" and (.metadata.name | test(\"^eso-in-cluster\")))] | .[] | .metadata.namespace + \"/\" + .metadata.name" \
    "argocd/eso-in-cluster-$c"
  # coupling: bound to the SA the principal chart renders for the store, in argocd, to this worker's Role only
  assert_yq "$w" "$sa_bindings | length" 1
  assert_yq "$w" "$sa_bindings | .[0] | .kind + \"/\" + .metadata.namespace + \"/\" + .roleRef.name + \" -> \" + .subjects[0].namespace + \"/\" + .subjects[0].name" \
    "RoleBinding/argocd/eso-in-cluster-$c -> argocd/$sa"
done
[ "$n" -ge 2 ] || fail "expected several worker cluster files, found $n"

# --- hub: no agent identity -> no grant
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="Role" or .kind=="RoleBinding")] | length' 0
