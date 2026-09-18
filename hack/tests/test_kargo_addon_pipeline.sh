#!/usr/bin/env bash
# One kargo-pipeline render = the whole Kargo pipeline for one worker addon (rendered manifests pattern).
source "$(dirname "$0")/lib.sh"
o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager --set chart=cert-manager \
      --set namespace=cert-manager --set releaseName=cert-manager)
assert_yq "$o" 'select(.kind=="Project") | .metadata.name' addon-cert-manager
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.includePaths | join(",")' \
  'repos/platform-charts/cert-manager/,repos/platform-config/addons/workers/cert-manager/'
assert_yq "$o" '[select(.kind=="Stage")] | map(.metadata.name) | join(",")' 'dev-canary,dev,test,prod'
assert_yq "$o" 'select(.kind=="Stage" and .metadata.name=="dev") | .spec.requestedFreight[0].sources.stages[0]' dev-canary
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.repoURL' 'git@github.com:koorikla/platform-lab.git'
