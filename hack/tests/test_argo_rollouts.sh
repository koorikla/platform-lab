#!/usr/bin/env bash
# Argo Rollouts (Kargo verification = AnalysisRuns) ships in the kargo umbrella: its CRDs must be in the same render
# as kargo-controller, which only detects them at startup.
source "$(dirname "$0")/lib.sh"
r=$(render kargo $charts/kargo -f $config/addons/management/kargo/values.yaml)
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysisruns.argoproj.io")] | length' 1
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysistemplates.argoproj.io")] | length' 1
# Argo must never delete the Rollouts CRDs (would cascade to every AnalysisRun/Template)
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .spec.group=="argoproj.io" and
  .metadata.annotations."argocd.argoproj.io/sync-options"!="Delete=false")] | length' 0
assert_yq "$r" '[select(.kind=="Deployment" and .metadata.name=="kargo-controller")] | length' 1
# exactly one rollouts controller, single replica, no dashboard
assert_yq "$r" '[select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/name"=="argo-rollouts")] | length' 1
assert_yq "$r" 'select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/name"=="argo-rollouts") | .spec.replicas' 1
assert_yq "$r" '[select(.kind=="Deployment" and .metadata.name=="*-dashboard")] | length' 0
# kargo-controller's Rollouts integration is on (env comes from this ConfigMap)
assert_yq "$r" 'select(.kind=="ConfigMap" and .metadata.name=="kargo-controller") | .data.ROLLOUTS_INTEGRATION_ENABLED' true
