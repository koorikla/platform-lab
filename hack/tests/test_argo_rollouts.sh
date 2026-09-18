#!/usr/bin/env bash
# Argo Rollouts (Kargo verification = AnalysisRuns) ships in the kargo umbrella: its CRDs must be in the same render
# as kargo-controller, which only detects them at startup.
source "$(dirname "$0")/lib.sh"
r=$(render kargo $charts/kargo -f $config/addons/management/kargo/values.yaml)
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysisruns.argoproj.io")] | length' 1
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysistemplates.argoproj.io")] | length' 1
assert_yq "$r" '[select(.kind=="Deployment" and .metadata.name=="kargo-controller")] | length' 1
assert_yq "$r" '[select(.kind=="Deployment" and .metadata.labels."app.kubernetes.io/name"=="argo-rollouts")] | length' 1
