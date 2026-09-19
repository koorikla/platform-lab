#!/usr/bin/env bash
# What a deleted Application takes with it. Renaming a file to .disabled deletes its generated Application; without
# preserveResourcesOnDeletion the appset controller puts resources-finalizer on it and Argo CD then deletes everything
# the app installed (capi-operator -> CAPI CRDs -> every Cluster; cluster-<name> -> Cluster -> CAPI teardown).
# Every ApplicationSet must be classified here, so a new one is a conscious choice.
source "$(dirname "$0")/lib.sh"
# infrastructure: disabling must orphan, never delete (removal is a manual step: CONTRIBUTING.md "Disabling")
preserve=" mgmt-addons fleet-clusters worker-addons "
# deletion is the point: a disabled worker addon's or removed app's Kargo pipeline must stop promoting; a removed
# app goes away (workloads)
cascade=" kargo-addon-pipelines kargo-app-pipelines workloads "

for f in $config/argocd/appset-*.yaml; do
  name=$(yq '.metadata.name' "$f")
  if [[ "$preserve" == *" $name "* ]]; then
    # appset level (spec.syncPolicy), not the Application template: there it is not a field
    assert_yq "$f" '.spec.syncPolicy.preserveResourcesOnDeletion' true
    assert_yq "$f" '.spec.template.spec.syncPolicy.preserveResourcesOnDeletion' null
    # template finalizers are copied verbatim and win over preserveResourcesOnDeletion
    assert_yq "$f" '.spec.template.metadata.finalizers' null
  elif [[ "$cascade" == *" $name "* ]]; then
    assert_yq "$f" '.spec.syncPolicy.preserveResourcesOnDeletion' null
  else
    fail "$f: ApplicationSet $name is in neither preserve nor cascade list of $0"
  fi
done
names=" $(yq eval-all '[.metadata.name] | join(" ")' $config/argocd/appset-*.yaml) "
for name in $preserve $cascade; do
  [[ "$names" == *" $name "* ]] || fail "$0 lists $name, but no ApplicationSet has that name"
done

# plain hub Applications (fleet-base: ClusterClass + HelmChartProxies = every worker's birth kit) must not cascade
# either when removed from git: root prunes them, and a finalizer would take their resources along
assert_yq "$config/argocd/apps.yaml" '[.metadata.finalizers // [] | .[]] | length' 0
