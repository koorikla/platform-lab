#!/usr/bin/env bash
# What a deleted Application takes with it. Renaming a file to .disabled deletes its generated Application; without
# preserveResourcesOnDeletion the appset controller puts resources-finalizer on it and Argo CD then deletes everything
# the app installed (capi-operator -> CAPI CRDs -> every Cluster; cluster-<name> -> Cluster -> CAPI teardown).
# Every ApplicationSet must be classified here, so a new one is a conscious choice.
source "$(dirname "$0")/lib.sh"
# infrastructure: disabling must orphan, never delete (removal is a manual step, see CLAUDE.md "Disabling")
preserve=" mgmt-addons fleet-clusters "
# deletion is the point: a disabled worker addon's Kargo pipeline must stop promoting; a removed app goes away.
# worker-addons: #36 moves it to preserve (asserted in its own test); add it here once that is merged.
cascade=" kargo-addon-pipelines workloads worker-addons "

for f in $config/argocd/appset-*.yaml; do
  name=$(yq '.metadata.name' "$f")
  if [[ "$preserve" == *" $name "* ]]; then
    # appset level (spec.syncPolicy), not the Application template: there it is not a field
    assert_yq "$f" '.spec.syncPolicy.preserveResourcesOnDeletion' true
    assert_yq "$f" '.spec.template.spec.syncPolicy.preserveResourcesOnDeletion' null
    # template finalizers are copied verbatim and win over preserveResourcesOnDeletion
    assert_yq "$f" '.spec.template.metadata.finalizers' null
  elif [[ "$cascade" != *" $name "* ]]; then
    fail "$f: ApplicationSet $name is in neither preserve nor cascade list of $0"
  fi
done
for name in $preserve; do
  grep -qx "  name: $name" $config/argocd/appset-*.yaml || fail "preserve list names missing ApplicationSet $name"
done

# plain hub Applications (fleet-base: ClusterClass + HelmChartProxies = every worker's birth kit) must not cascade
# either when removed from git: root prunes them, and a finalizer would take their resources along
assert_yq "$config/argocd/apps.yaml" '[.metadata.finalizers // [] | .[]] | length' 0
