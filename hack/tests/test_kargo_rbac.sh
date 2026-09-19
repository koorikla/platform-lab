#!/usr/bin/env bash
# Kargo per-project roles (#20), across every Kargo project the repo defines (config x kargo-pipeline): the chart's own
# behaviour (trio, rules, promotedBy, guards) is repos/platform-charts/kargo-pipeline/tests/rbac_test.yaml. Here: the
# policy holds for the projects the kargo-*-pipelines appsets actually create - app projects let developers promote
# the early stages, never the last one; addon projects give people no per-project rights (admins/platform-engineers
# promote through the global kargo-admin, test_sso_oidc.sh). Stage names come from the values, never hard-coded.
source "$(dirname "$0")/lib.sh"
v=$charts/kargo-pipeline/values.yaml
first=$(yq '.stages[0].name' "$v")
last=$(yq '.stages[-1].name' "$v")
promote='[select(.kind=="Role") | .rules[] | select(.verbs | contains(["promote"]))]'

apps=0
for f in repos/apps/*/app.yaml; do
  a=$(basename "$(dirname "$f")")
  x=$(render "k-$a" "$charts/kargo-pipeline" --set kind=app,name="$a",image="$(yq .image.repository "$f")")
  names=$(yq eval-all "$promote | map(.resourceNames // [] | join(\",\")) | join(\";\")" "$x")
  [[ ,$names, == *,$first,* ]] || fail "app-$a: developers can't promote into the first stage $first: '$names'"
  [[ ,$names, != *,$last,* ]] || fail "app-$a: someone may promote into the last stage $last per project: '$names'"
  assert_yq "$x" "$promote | map(.resourceNames // [] | length) | map(select(. == 0)) | length" 0   # never "every stage"
  assert_yq "$x" 'select(.kind=="ServiceAccount" and .metadata.name=="developer") | .metadata.annotations["rbac.kargo.akuity.io/claims"]' '{"groups":["developers"]}'
  apps=$((apps + 1))
done
[ "$apps" -gt 0 ] || fail "no app pipelines found"
for f in "$config"/addons/workers/*/addon.yaml; do
  a=$(basename "$(dirname "$f")"); x=$(render "k-$a" "$charts/kargo-pipeline" --set kind=addon,name="$a")
  assert_yq "$x" "$promote | length" 0
  assert_yq "$x" '[select(.metadata.annotations["rbac.kargo.akuity.io/claims"] != null)] | length' 0
done
