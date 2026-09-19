#!/usr/bin/env bash
# App pipelines (#16): repos/apps/<app>/app.yaml -> ApplicationSet kargo-app-pipelines -> kargo-pipeline (kind=app):
# Kargo Project app-<app>, Warehouse on the image + the app's config, Stages running the render-app
# ClusterPromotionTask, which renders openchoreo-app (mode=release) into rendered/<stage>:apps/<app>/release/.
# Kargo writes only rendered/* (invariant 5): no promotion writes main.
source "$(dirname "$0")/lib.sh"
stage() { echo "select(.kind==\"Stage\" and .metadata.name==\"$1\")"; }
var() { echo "$(stage "$1") | .spec.promotionTemplate.spec.steps[0].vars[] | select(.name==\"$2\") | .value"; }
ra=$config/kargo/shared/render-app.yaml
kp=$charts/kargo-pipeline

# --- kargo-pipeline, kind=app
o=$(render p $kp --set kind=app --set name=podinfo --set image=ghcr.io/stefanprodan/podinfo --set imageConstraint=^6.0.0)
assert_yq "$o" 'select(.kind=="Project") | .metadata.name' app-podinfo
assert_yq "$o" 'select(.kind=="Namespace") | .metadata.labels["kargo.akuity.io/project"]' true
assert_yq "$o" '[select(.kind=="Warehouse")] | length' 1
w='select(.kind=="Warehouse") | .spec.subscriptions'
assert_yq "$o" "${w} | length" 2
# a new image tag is Freight...
assert_yq "$o" "${w}[0].image.repoURL" ghcr.io/stefanprodan/podinfo
assert_yq "$o" "${w}[0].image.imageSelectionStrategy" SemVer
assert_yq "$o" "${w}[0].image.constraint" '^6.0.0'
# ...and so is a main commit changing what the release freezes: the app's definition/env config or the chart
assert_yq "$o" "${w}[1].git.repoURL" 'git@github.com:koorikla/platform-lab.git'
assert_yq "$o" "${w}[1].git.branch" main
assert_yq "$o" "${w}[1].git.includePaths | join(\",\")" 'repos/apps/podinfo/,repos/platform-charts/openchoreo-app/'
# same stages as addons: a canary-ring cluster binds from rendered/dev-canary (#17), so apps need that branch too
assert_yq "$o" '[select(.kind=="Stage")] | map(.metadata.name) | join(",")' \
  "$(yq '.stages | map(.name) | join(",")' $kp/values.yaml)"
assert_yq "$o" "[select(.kind==\"Stage\")] | map(.metadata.name) | contains([\"dev-canary\"])" true
assert_yq "$o" "$(var dev-canary app)" podinfo
assert_yq "$o" "$(var dev-canary image)" ghcr.io/stefanprodan/podinfo
assert_yq "$o" "$(var dev-canary env)" dev
assert_yq "$o" "$(var dev-canary branch)" dev-canary
assert_yq "$o" "$(var prod branch)" prod
# contract: every Stage passes exactly the vars render-app declares, to the task of that name
want=$(yq '.spec.vars[].name' $ra | sort | paste -sd, -)
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].vars | map(.name) | sort | join(",")]
  | unique | join(";")' "$want"
assert_yq "$o" '[select(.kind=="Stage") | .spec.promotionTemplate.spec.steps[0].task.name] | unique | join(",")' \
  "$(yq .metadata.name $ra)"
# the image var names the Warehouse subscription imageFrom() looks the Freight up by
assert_yq "$o" "[select(.kind==\"Stage\") | .spec.promotionTemplate.spec.steps[0].vars[] | select(.name==\"image\")
  | .value] | unique | join(\",\")" "$(yq eval-all "${w}[0].image.repoURL" "$o")"
# no constraint: any semver tag (no empty constraint field)
n=$(render p $kp --set kind=app --set name=foo --set image=example.org/foo)
assert_yq "$n" "${w}[0].image | has(\"constraint\")" false
# an addon pipeline has no app Warehouse and vice versa
a=$(render p $kp --set name=cert-manager)
assert_yq "$a" "[select(.kind==\"Warehouse\")] | length" 1
assert_yq "$a" "${w} | map(has(\"image\")) | any" false
assert_fails helm template p $kp --set kind=app --set name=foo                     # no image

# --- render-app: shape (same conventions as render-addon)
h='.spec.steps[] | select(.uses=="helm-template") | .config'
assert_yq "$ra" '.kind' ClusterPromotionTask
assert_yq "$ra" "[.spec.steps[] | select(.uses==\"helm-template\")] | length" 1
assert_yq "$ra" "$h | .path" './src/repos/platform-charts/openchoreo-app'
# the pipeline owns apps/<app>/ on its branch: cleared, then re-rendered, so removed resources and superseded
# releases leave the branch; other apps and addons on the branch are other pipelines' output
assert_yq "$ra" '[.spec.steps[] | select(.uses=="delete") | .config.path] | join(",")' './out/apps/${{ vars.app }}'
assert_yq "$ra" '[.spec.steps[].uses] | (to_entries | map(select(.value=="delete")) | .[0].key) <
  (to_entries | map(select(.value=="helm-template")) | .[0].key)' true
assert_yq "$ra" "$h | .outPath" './out/apps/${{ vars.app }}/release'
assert_yq "$ra" "$h | .outLayout" flat
assert_yq "$ra" "$h | .ignoreMissingValueFiles" true                  # envs/<env>/values.yaml is optional
# a tag like 1.10 must stay a string: Kargo turns a number-like expression result into a float unless quote()d, and
# helm's --set does the same unless literal
assert_yq "$ra" "$h | .setValues[] | select(.key==\"image.tag\") | .value" '${{ quote(imageFrom(vars.image).Tag) }}'
assert_yq "$ra" "$h | .setValues[] | select(.key==\"image.tag\") | .literal" true
# every custom if keeps the implicit "previous steps succeeded" guard (see render-addon.yaml)
assert_yq "$ra" '[.spec.steps[] | select(has("if"))] | length > 0' true
assert_yq "$ra" '[.spec.steps[] | select(has("if")) | .if | test("^[$][{][{] success[(][)] && ")] | all' true
assert_yq "$ra" '.spec.steps[-1].as' result
assert_yq "$ra" '.spec.steps[-1].uses' compose-output

# --- invariant 5: Kargo writes only rendered/* (the podinfo main-writing promotion is gone, #16)
while IFS= read -r f; do
  assert_yq "$f" '[.spec.steps[]? | select(.uses=="git-clone") | .config.checkout[] | select(has("branch"))
    | .branch | test("^rendered/")] | all' true
  assert_yq "$f" '[.spec.steps[]? | select(.uses=="yaml-update")] | length' 0
done < <(find $config/kargo -name '*.yaml')
[ ! -e $config/kargo/podinfo ] || fail "kargo/podinfo (writes main) must be gone: replaced by app-podinfo"

# --- every app: what render-app writes, simulated from the task definition itself.
# Substitutes the task's vars/expressions (unknown ones fail), passes valuesFiles/setValues the way Kargo does
# (--set, or --set-literal for literal: true; missing values files skipped), then applies Kargo's flat file naming.
tag=1.10                                           # float-looking on purpose (literal check)
wstage=$(yq '.workloadStage' $charts/openchoreo-app/values.yaml)
subst() {   # subst <string> <app> <env> <stage>
  local s=$1
  s=${s//'${{ vars.app }}'/$2}; s=${s//'${{ vars.env }}'/$3}; s=${s//'${{ vars.branch }}'/$4}
  s=${s//'${{ quote(imageFrom(vars.image).Tag) }}'/$tag}
  [[ $s != *'${{'* ]] || fail "render-app: unknown expression in '$s'"
  echo "${s#./src/}"
}
apps=0
for af in repos/apps/*/app.yaml; do
  app=$(basename "$(dirname "$af")"); apps=$((apps + 1))
  assert_yq "$af" '.name' "$app"                   # folder == Component name == Kargo project suffix
  [ -n "$(yq '.image.repository // ""' "$af")" ] || fail "$af: image.repository is required (the Warehouse)"
  # main holds no versions for promoted things: the tag is the Freight's
  for f in "$af" $(find "$(dirname "$af")/envs" -name values.yaml 2>/dev/null); do
    assert_yq "$f" '[.. | select(tag == "!!map" and has("tag"))] | length' 0
  done
  for s in $(yq '.stages[].name' $kp/values.yaml); do
    env=$(yq ".stages[] | select(.name==\"$s\") | .env" $kp/values.yaml)
    args=()
    while IFS= read -r v; do
      v=$(subst "$v" "$app" "$env" "$s"); [ ! -f "$v" ] || args+=(-f "$v")
    done < <(yq "$h | .valuesFiles[]" $ra)
    while IFS=$'\t' read -r k v lit; do
      v=$(subst "$v" "$app" "$env" "$s")
      if [ "$lit" = true ]; then args+=(--set-literal "$k=$v"); else args+=(--set "$k=$v"); fi
    done < <(yq -r "$h | .setValues[] | [.key, .value, (.literal // false)] | @tsv" $ra)
    r=$(render "$app" "$(subst "$(yq "$h | .path" $ra)" "$app" "$env" "$s")" "${args[@]}")
    # exactly one release per stage folder, named <app>-<stage>-<tag>-<hash8>
    assert_yq "$r" '[select(.kind != null) | .kind] | unique | sort | join(",")' \
      "$([ "$s" = "$wstage" ] && echo ComponentRelease,Workload || echo ComponentRelease)"
    rel=$(yq eval-all 'select(.kind=="ComponentRelease") | .metadata.name' "$r")
    [[ $rel =~ ^$app-$s-1-10-[0-9a-f]{8}$ ]] || fail "$app/$s: release name $rel"
    assert_yq "$r" 'select(.kind=="ComponentRelease") | .spec.workload.container.image' \
      "$(yq .image.repository "$af"):$tag"
    # Kargo flat layout (helm_template_runner.go generateResourceFilename, v1.11.4): the file names #17 matches on
    # (per document: yq e, not eval-all). Every rendered kind is namespaced and grouped, so all four parts exist.
    files=$(yq e -N 'select(.kind != null) | [(.apiVersion | split("/") | .[0] | sub("\.", "_")), .kind,
      .metadata.namespace, .metadata.name] | join("-") | downcase + ".yaml"' "$r")
    [ "$(grep -c '^openchoreo_dev-componentrelease-' <<<"$files")" = 1 ] || fail "$app/$s: files $files"
    grep -qx "openchoreo_dev-componentrelease-default-$rel.yaml" <<<"$files" || fail "$app/$s: files $files"
  done
  # the Component (hub, from main in #17) renders from app.yaml alone
  c=$(render "$app" $charts/openchoreo-app -f "$af" --set mode=component)
  assert_yq "$c" 'select(.kind=="Component") | .metadata.name' "$app"
done
[ "$apps" -gt 0 ] || fail "no repos/apps/*/app.yaml"

# --- ApplicationSet kargo-app-pipelines: one pipeline per app.yaml (app.yaml.disabled => none)
s=$config/argocd/appset-kargo-app-pipelines.yaml
assert_yq "$s" '.metadata.name' kargo-app-pipelines
assert_yq "$s" '.spec.goTemplateOptions | join(",")' 'missingkey=error'
assert_yq "$s" '.spec.generators[0].git.files | map(.path) | join(",")' 'repos/apps/*/app.yaml'
assert_yq "$s" '.spec.template.spec.source.path' "$kp"
assert_yq "$s" '.spec.template.spec.project' platform-mgmt
# the generated Application, fed back into kargo-pipeline
p=$tmp/params.yaml
yq '. + {"path": {"path": "repos/apps/podinfo", "basename": "podinfo", "filename": "app.yaml"}}' \
  repos/apps/podinfo/app.yaml > "$p"
g=$tmp/gen.yaml; gotpl "$(yq '.spec.template' "$s")" "$p" > "$g"
assert_yq "$g" '.metadata.name' kargo-app-podinfo
yq '.spec.source.helm.valuesObject' "$g" > "$tmp/vo.yaml"
assert_yq "$tmp/vo.yaml" '.kind' app
v=$(render p $kp -f "$tmp/vo.yaml")
assert_yq "$v" 'select(.kind=="Project") | .metadata.name' app-podinfo
assert_yq "$v" "${w}[0].image.repoURL" "$(yq .image.repository repos/apps/podinfo/app.yaml)"
assert_yq "$v" "${w}[0].image.constraint" "$(yq .image.constraint repos/apps/podinfo/app.yaml)"
# an app.yaml without a constraint: no constraint (not "<no value>")
printf 'name: foo\nimage: { repository: example.org/foo }\n' > "$tmp/foo.yaml"
yq '. + {"path": {"path": "repos/apps/foo", "basename": "foo", "filename": "app.yaml"}}' "$tmp/foo.yaml" > "$p"
gotpl "$(yq '.spec.template' "$s")" "$p" | yq '.spec.source.helm.valuesObject' > "$tmp/vo.yaml"
v=$(render p $kp -f "$tmp/vo.yaml")
assert_yq "$v" "${w}[0].image | has(\"constraint\")" false
