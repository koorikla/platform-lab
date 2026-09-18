#!/usr/bin/env bash
# hub runs the Argo Rollouts controller (Kargo verification = AnalysisRuns): CRDs installed, controller only
source "$(dirname "$0")/lib.sh"
r=$(render argo-rollouts $charts/argo-rollouts -f $config/addons/management/argo-rollouts/values.yaml)
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysisruns.argoproj.io")] | length' 1
assert_yq "$r" '[select(.kind=="CustomResourceDefinition" and .metadata.name=="analysistemplates.argoproj.io")] | length' 1
assert_yq "$r" '[select(.kind=="Deployment")] | length' 1
