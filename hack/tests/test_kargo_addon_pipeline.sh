#!/usr/bin/env bash
# One kargo-pipeline render = the whole Kargo pipeline for one worker addon (rendered manifests pattern).
source "$(dirname "$0")/lib.sh"
stage() { echo "select(.kind==\"Stage\" and .metadata.name==\"$1\")"; }
var() { echo "$(stage "$1") | .spec.promotionTemplate.spec.steps[0].vars[] | select(.name==\"$2\") | .value"; }

o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager --set chart=cert-manager \
      --set namespace=cert-manager --set releaseName=cert-manager)
assert_yq "$o" 'select(.kind=="Project") | .metadata.name' addon-cert-manager
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.includePaths | join(",")' \
  'repos/platform-charts/cert-manager/,repos/platform-config/addons/workers/cert-manager/'
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.repoURL' 'git@github.com:koorikla/platform-lab.git'
assert_yq "$o" 'select(.kind=="ProjectConfig") | .spec.promotionPolicies | map(.stageSelector.name) | join(",")' 'dev-canary,dev'
# stage chain: first takes Freight from the Warehouse, each next one from its predecessor
assert_yq "$o" '[select(.kind=="Stage")] | map(.metadata.name) | join(",")' 'dev-canary,dev,test,prod'
assert_yq "$o" "$(stage dev-canary) | .spec.requestedFreight[0].sources.direct" true
assert_yq "$o" "$(stage dev) | .spec.requestedFreight[0].sources.stages[0]" dev-canary
assert_yq "$o" "$(stage prod) | .spec.requestedFreight[0].sources.stages[0]" test
# dev-canary renders dev values into its own branch
assert_yq "$o" "$(var dev-canary env)" dev
assert_yq "$o" "$(var dev-canary branch)" dev-canary
assert_yq "$o" "$(var prod branch)" prod
assert_yq "$o" "$(var prod pr)" false
assert_yq "$o" "$(var dev repoURL)" 'git@github.com:koorikla/platform-lab.git'

# contract: every Stage passes exactly the vars render-addon declares, to the task of that name
want=$(yq '.spec.vars[].name' $config/kargo/shared/render-addon.yaml | sort | paste -sd, -)
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].vars | map(.name) | sort | join(",")]
  | unique | join(";")' "$want"
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].task.name] | unique | join(",")' \
  "$(yq .metadata.name $config/kargo/shared/render-addon.yaml)"

# helper defaults: omitted chart/namespace/releaseName fall back to name; an explicit chart wins everywhere
d=$(render p $charts/kargo-pipeline --set name=foo)
assert_yq "$d" "[$(var dev chart), $(var dev namespace), $(var dev releaseName)] | join(\",\")" 'foo,foo,foo'
c=$(render p $charts/kargo-pipeline --set name=foo --set chart=bar)
assert_yq "$c" "$(var dev chart)" bar
assert_yq "$c" "$(var dev addon)" foo
assert_yq "$c" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.includePaths[0]' 'repos/platform-charts/bar/'

# rejected renders
assert_fails helm template p $charts/kargo-pipeline
assert_fails helm template p $charts/kargo-pipeline --set name=foo --set kind=bogus
