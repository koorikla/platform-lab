#!/usr/bin/env bash
# Kargo per-project roles (#20). Global roles come from the kargo chart (hub values, test_sso_oidc.sh): kargo-admin for
# admins + platform-engineers (promote everywhere), kargo-viewer for developers + sres (read-only). In app projects,
# developers may promote only into the stages marked `promotedBy: [developer]` in kargo-pipeline's values (the early
# ones); addon projects are platform-owned and get no per-project role. Kargo 1.11.4 model: a user maps to ServiceAccounts in the project namespace by the rbac.kargo.akuity.io/claims
# annotation; kargo-api runs a SubjectAccessReview per SA for verb `promote` on stages/<stage>
# (pkg/server/kubernetes/client.go getAuthorizedClient, promote_to_stage_v1alpha1.go), and creates the Promotion only
# if one of them may `create` promotions in the project namespace. Stage names are read from the values, never
# hard-coded here: renaming environments must not need this test or the template changed.
source "$(dirname "$0")/lib.sh"
v=$charts/kargo-pipeline/values.yaml
dev_stages=$(yq '[.stages[] | select((.promotedBy // []) | contains(["developer"])) | .name] | sort | join(",")' "$v")
all_stages=$(yq '[.stages[].name] | join(",")' "$v")
last=$(yq '.stages[-1].name' "$v")
first=$(yq '.stages[0].name' "$v")
sel() { echo "select(.kind==\"$1\" and .metadata.name==\"$2\")"; }
# policy: developers reach the first stage (stopping a bad canary = promoting older Freight into it), never the last
[[ ,$dev_stages, == *,$first,* ]] || fail "developers can't promote into the first stage $first: '$dev_stages'"
[[ ,$dev_stages, != *,$last,* ]] || fail "developers may promote into the last stage $last: '$dev_stages'"
[ "$dev_stages" != "$(tr , '\n' <<<"$all_stages" | sort | paste -sd, -)" ] || fail "developers may promote every stage"

# developer <render> <project>: the trio is complete and grants exactly $dev_stages
developer() {
  assert_yq "$1" "$(sel ServiceAccount developer) | .metadata.namespace" "$2"
  assert_yq "$1" "$(sel ServiceAccount developer) | .metadata.annotations[\"rbac.kargo.akuity.io/claims\"] | from_json | .groups | join(\",\")" developers
  assert_yq "$1" "$(sel Role developer) | .metadata.namespace" "$2"
  assert_yq "$1" "$(sel Role developer) | [.rules[] | select(.verbs | contains([\"promote\"]))] | length" 1
  assert_yq "$1" "$(sel Role developer) | .rules[] | select(.verbs | contains([\"promote\"])) | .apiGroups[0] + \"/\" + .resources[0] + \"=\" + (.resourceNames | sort | join(\",\"))" "kargo.akuity.io/stages=$dev_stages"
  # the Promotion itself: create only (no delete/patch = can't abort or rewrite others' promotions)
  assert_yq "$1" "$(sel Role developer) | .rules[] | select(.resources | contains([\"promotions\"])) | .verbs | join(\",\")" create
  # nothing else: reads come from the global kargo-viewer; Freight approval (freights/status) skips verification
  assert_yq "$1" "$(sel Role developer) | .rules | length" 2
  assert_yq "$1" "$(sel RoleBinding developer) | .metadata.namespace" "$2"
  assert_yq "$1" "$(sel RoleBinding developer) | .roleRef.kind + \"/\" + .roleRef.name" Role/developer
  assert_yq "$1" "$(sel RoleBinding developer) | .subjects | map(.kind + \"/\" + .namespace + \"/\" + .name) | join(\",\")" "ServiceAccount/$2/developer"
}

# every Kargo project the repo defines: one per worker addon, one per app (the kargo-*-pipelines appsets)
all=$(mktemp "$tmp/all.XXXXXX")
for f in "$config"/addons/workers/*/addon.yaml; do
  a=$(basename "$(dirname "$f")"); x=$(render "k-$a" "$charts/kargo-pipeline" --set kind=addon,name="$a")
  # addon pipelines: no per-project people RBAC at all (only admins/platform-engineers promote them)
  assert_yq "$x" '[select(.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding")
    | select(.metadata.annotations["rbac.kargo.akuity.io/claims"] != null or .metadata.name == "developer")] | length' 0
  assert_yq "$x" '[select(.kind=="Role") | .rules[] | select(.verbs | contains(["promote"]))] | length' 0
  cat "$x" >>"$all"
done
for f in repos/apps/*/app.yaml; do
  a=$(basename "$(dirname "$f")")
  x=$(render "k-$a" "$charts/kargo-pipeline" --set kind=app,name="$a",image="$(yq .image.repository "$f")")
  developer "$x" "app-$a"; cat "$x" >>"$all"
done
# nothing grants promote without resourceNames (= every stage), nor into the last stage
assert_yq "$all" '[select(.kind=="Role") | .rules[] | select(.verbs | contains(["promote"])) | (.resourceNames // []) | length]
  | map(select(. == 0)) | length' 0
assert_yq "$all" "[select(.kind==\"Role\") | .rules[] | select(.verbs | contains([\"promote\"])) | .resourceNames[]]
  | map(select(. == \"$last\")) | length" 0
# names Kargo's management controller owns in every project namespace (it rewrites their Role rules): never ours
for n in kargo-admin kargo-viewer kargo-promoter default; do
  assert_yq "$all" "[select(.metadata.name==\"$n\" and (.kind==\"ServiceAccount\" or .kind==\"Role\" or .kind==\"RoleBinding\"))] | length" 0
done

# stage lists come from `stages`: renamed stages carry the role along, no template change
printf 'kind: app\nimage: a/b\nstages:\n  - { name: a, env: dev, promotedBy: [developer] }\n  - { name: b, env: dev }\n  - { name: c, env: dev, promotedBy: [developer] }\n' >"$tmp/renamed.yaml"
x=$(render p "$charts/kargo-pipeline" --set name=foo -f "$tmp/renamed.yaml")
assert_yq "$x" "$(sel Role developer) | .rules[0].resourceNames | join(\",\")" a,c
# the same stages in an addon pipeline: nothing (the role is kinds: [app])
printf 'kind: addon\n' >"$tmp/addon.yaml"
y=$(render p "$charts/kargo-pipeline" --set name=foo -f "$tmp/renamed.yaml" -f "$tmp/addon.yaml")
assert_yq "$y" '[select(.metadata.name=="developer")] | length' 0
# a role no stage names renders nothing (never an empty resourceNames)
printf 'kind: app\nimage: a/b\nstages:\n  - { name: a, env: dev }\n' >"$tmp/none.yaml"
x=$(render p "$charts/kargo-pipeline" --set name=foo -f "$tmp/none.yaml")
assert_yq "$x" '[select(.metadata.name=="developer")] | length' 0
# typos fail the render: an unknown role on a stage, a role without groups
printf 'stages:\n  - { name: a, env: dev, promotedBy: [devloper] }\n' >"$tmp/typo.yaml"   # any kind
assert_fails helm template p "$charts/kargo-pipeline" --set name=foo -f "$tmp/typo.yaml"
printf 'promoters:\n  - { name: developer, groups: [], kinds: [app] }\n' >"$tmp/nogroups.yaml"
assert_fails helm template p "$charts/kargo-pipeline" --set name=foo -f "$tmp/nogroups.yaml"
printf 'promoters:\n  - { name: developer, groups: [developers] }\n' >"$tmp/nokinds.yaml"
assert_fails helm template p "$charts/kargo-pipeline" --set name=foo -f "$tmp/nokinds.yaml"
