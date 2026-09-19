#!/usr/bin/env bash
# One kargo-pipeline render = the whole Kargo pipeline for one worker addon (rendered manifests pattern). What the chart
# renders: its unit tests (repos/platform-charts/kargo-pipeline/tests/). Here: the contracts with the config repo -
# what an addon folder may hold (it is all Freight) and the render-addon task every Stage runs.
source "$(dirname "$0")/lib.sh"
ra=$config/kargo/shared/render-addon.yaml
o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager --set chart=cert-manager \
      --set namespace=cert-manager --set releaseName=cert-manager)

# everything in the addon's config folder is rendered (fleet + env values), so all of it is Freight (the Warehouse
# excludes nothing), and the folder holds nothing else: no rollout pins (envs/<env>.yaml), no per-cluster values
# (clusters/). Versions travel as Freight into rendered/<stage>; per-cluster identity comes from the CAAPH birth kit
# (invariants 5, 7).
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.includePaths[1]' \
  "$config/addons/workers/cert-manager/"
for a in $config/addons/workers/*/; do
  extra=$(cd "$a" && find . -type f ! -name 'addon.yaml*' ! -path ./values.yaml ! -path './envs/*.values.yaml' | sort)
  [ -z "$extra" ] || fail "$a: only addon.yaml, values.yaml, envs/<env>.values.yaml belong here, found: $extra"
done

# contract: every Stage passes exactly the vars render-addon declares, to the task of that name
want=$(yq '.spec.vars[].name' $ra | sort | paste -sd, -)
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].vars | map(.name) | sort | join(",")]
  | unique | join(";")' "$want"
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].task.name] | unique | join(",")' \
  "$(yq .metadata.name $ra)"

# a custom if replaces Kargo's implicit "previous steps succeeded" guard: every one must keep it explicitly
assert_yq "$ra" '[.spec.steps[] | select(has("if"))] | length > 0' true
assert_yq "$ra" '[.spec.steps[] | select(has("if")) | .if | test("^[$][{][{] success[(][)] && ")] | all' true
