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
# everything in the addon's config folder is rendered (fleet + env values), so all of it is Freight: no excludes
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git | has("excludePaths")' false
# ...and the folder holds nothing else: no rollout pins (envs/<env>.yaml), no per-cluster values (clusters/). Versions
# travel as Freight into rendered/<stage>; per-cluster identity comes from the CAAPH birth kit (invariants 5, 7).
for a in $config/addons/workers/*/; do
  extra=$(cd "$a" && find . -type f ! -name 'addon.yaml*' ! -path ./values.yaml ! -path './envs/*.values.yaml' | sort)
  [ -z "$extra" ] || fail "$a: only addon.yaml, values.yaml, envs/<env>.values.yaml belong here, found: $extra"
done
assert_yq "$o" 'select(.kind=="ProjectConfig") | .spec.promotionPolicies | map(.stageSelector.name) | join(",")' 'dev-canary,dev'
# stage chain: first takes Freight from the Warehouse, each next one from its predecessor
assert_yq "$o" '[select(.kind=="Stage")] | map(.metadata.name) | join(",")' 'dev-canary,dev,test,prod'
assert_yq "$o" "$(stage dev-canary) | .spec.requestedFreight[0].sources.direct" true
assert_yq "$o" "$(stage dev) | .spec.requestedFreight[0].sources.stages[0]" dev-canary
assert_yq "$o" "$(stage prod) | .spec.requestedFreight[0].sources.stages[0]" test
# canary ring (#5, #26): dev auto-promotes, but only Freight verified in dev-canary (its Applications Synced + Healthy
# at the promoted commit, test_kargo_verification.sh). Without that gate dev follows the canary within seconds and the
# ring shows nothing. No soak by default (a timer that ignores health); `soak` stays available per stage.
assert_yq "$o" "[select(.kind==\"Stage\") | .spec.requestedFreight[0].sources | has(\"requiredSoakTime\")] | any" false
# rule: an auto-promoted stage fed by a *-canary stage waits for that stage's verification
auto=" $(yq eval-all 'select(.kind=="ProjectConfig") | .spec.promotionPolicies[] | select(.autoPromotionEnabled) | .stageSelector.name' "$o" | paste -sd' ' -) "
[[ $auto == *" dev "* ]] || fail "dev must auto-promote (after dev-canary's verification), auto-promoted: '$auto'"
for s in $(yq eval-all 'select(.kind=="Stage" and ((.spec.requestedFreight[0].sources.stages[0] // "") | test("-canary$"))) | .metadata.name' "$o"); do
  up=$(yq eval-all "$(stage "$s") | .spec.requestedFreight[0].sources.stages[0]" "$o")
  [[ $auto != *" $s "* ]] || [ "$(yq eval-all "$(stage "$up") | .spec.verification.analysisTemplates | length" "$o")" -gt 0 ] ||
    fail "stage $s auto-promotes from canary stage $up, which verifies nothing"
done
# the first stage takes Freight from the Warehouse: there is nothing to soak in
printf 'stages:\n  - { name: a, env: dev, soak: 5m }\n' > "$tmp/soak-first.yaml"
assert_fails helm template p $charts/kargo-pipeline --set name=foo -f "$tmp/soak-first.yaml"
# soak must be a Kargo duration (CRD pattern): a bare number fails the render, not the Kargo webhook after an Argo sync
printf 'stages:\n  - { name: a, env: dev }\n  - { name: b, env: dev, soak: %s }\n' 15 > "$tmp/soak-bad.yaml"
assert_fails helm template p $charts/kargo-pipeline --set name=foo -f "$tmp/soak-bad.yaml"
printf 'stages:\n  - { name: a, env: dev }\n  - { name: b, env: dev, soak: %s }\n' 1h30m > "$tmp/soak-ok.yaml"
s=$(render p $charts/kargo-pipeline --set name=foo -f "$tmp/soak-ok.yaml")
assert_yq "$s" "$(stage b) | .spec.requestedFreight[0].sources.requiredSoakTime" 1h30m
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

# a custom if replaces Kargo's implicit "previous steps succeeded" guard: every one must keep it explicitly
ra=$config/kargo/shared/render-addon.yaml
assert_yq "$ra" '[.spec.steps[] | select(has("if"))] | length > 0' true
assert_yq "$ra" '[.spec.steps[] | select(has("if")) | .if | test("^[$][{][{] success[(][)] && ")] | all' true
# the task step's alias is how later Stage steps read its output (outputs.render.commit)
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].as] | unique | join(",")' render
