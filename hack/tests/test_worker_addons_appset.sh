#!/usr/bin/env bash
# worker-addons: addon x worker cluster, synced as a plain directory from Kargo's rendered/<env>[-canary] branch.
# ApplicationSets can't be rendered offline: assert the structure, then execute its Go templates with helm's `tpl`
# (text/template + sprig, like the appset controller) against params shaped like the generators' output.
# Not covered: missingkey behaviour. helm's tpl runs missingkey=zero with map[string]interface{} labels (a missing label
# is nil), the controller missingkey=error with map[string]string labels (`index` gives ""). The "no ring label =>
# stable" case holds in both, for different reasons; a typo'd field shows up here as a wrong value, not an error.
source "$(dirname "$0")/lib.sh"
a=$config/argocd/appset-worker-addons.yaml
g='.spec.generators[0].matrix.generators'

assert_yq "$a" '.spec.goTemplate' true
assert_yq "$a" '.spec.goTemplateOptions | join(",")' 'missingkey=error'
assert_yq "$a" '.spec.syncPolicy.preserveResourcesOnDeletion' true
assert_yq "$a" "$g | length" 2
assert_yq "$a" "$g[0].git.revision" main
assert_yq "$a" "$g[0].git.files | map(.path) | join(\",\")" 'repos/platform-config/addons/workers/*/addon.yaml'
assert_yq "$a" "$g[1].clusters.selector.matchLabels | to_entries | map(.key + \"=\" + .value) | join(\",\")" \
  'platform.lab/role=worker'
# plain directory from a rendered branch: no helm, no kustomize, no $values source, no per-cluster patching
assert_yq "$a" '.spec.template.spec | has("sources")' false
assert_yq "$a" '.spec.template.spec.source | keys | sort | join(",")' 'directory,path,repoURL,targetRevision'
assert_yq "$a" '.spec.template.spec.source.directory.recurse' true
assert_yq "$a" '.spec | has("templatePatch")' false
assert_yq "$a" '.spec.template.spec.syncPolicy.syncOptions | join(",")' \
  'CreateNamespace=true,ServerSideApply=true,SkipDryRunOnMissingResource=true'

# gotpl <template string> <context yaml file> -> the rendered string
mkdir -p "$tmp/tpl/templates"
printf 'apiVersion: v2\nname: tpl\nversion: 0.0.0\n' > "$tmp/tpl/Chart.yaml"
echo 'out: {{ tpl .Values.t .Values.ctx | toJson }}' > "$tmp/tpl/templates/out.yaml"   # helm wants a mapping
gotpl() {
  printf '%s' "$1" > "$tmp/t.txt"
  yq -n ".ctx = load(\"$2\")" > "$tmp/ctx.yaml"
  helm template tpl "$tmp/tpl" -f "$tmp/ctx.yaml" --set-file t="$tmp/t.txt" | yq -N '.out' ||
    fail "gotpl: $1"
}
# app <addon folder> <cluster labels as k=v,...> [addon.yaml] -> file with the generated Application for that pair
app() {
  local dir=$config/addons/workers/$1 c="$tmp/cluster.yaml" p="$tmp/params.yaml" k out
  local f=${3:-$config/addons/workers/$1/addon.yaml}
  out=$(mktemp "$tmp/app.XXXXXX")
  # clusters generator: name + metadata.labels of the Argo cluster secret, then its templated `values`
  yq -n '.name = "dev9" | .metadata.labels = {}' > "$c"
  for kv in ${2//,/ }; do yq -i ".metadata.labels[\"${kv%%=*}\"] = \"${kv#*=}\"" "$c"; done
  for k in $(yq "$g[1].clusters.values | keys | .[]" "$a"); do
    v=$(gotpl "$(yq "$g[1].clusters.values.$k" "$a")" "$c") yq -i ".values.$k = strenv(v)" "$c"
  done
  # git files generator: the file's content + path params under pathParamPrefix
  pp=$(yq "$g[0].git.pathParamPrefix" "$a")
  yq ". * load(\"$c\") | .$pp.path = {\"path\": \"$dir\", \"basename\": \"$1\", \"filename\": \"addon.yaml\"}" \
    "$f" > "$p"
  gotpl "$(yq '.spec.template' "$a")" "$p" > "$out"
  echo "$out"
}

# the branch must be one Kargo writes: kargo-pipeline Stage name == rendered/<name>
k=$(render p $charts/kargo-pipeline --set name=x)
branch() { assert_yq "$1" '.spec.source.targetRevision' "rendered/$2"
  assert_yq "$k" "[select(.kind==\"Stage\") | .metadata.name] | contains([\"$2\"])" true; }

o=$(app cert-manager platform.lab/role=worker,platform.lab/env=dev,platform.lab/ring=stable)
branch "$o" dev
assert_yq "$o" '.metadata.name' cert-manager-dev9
assert_yq "$o" '.metadata.labels["argocd-agent"]' true
assert_yq "$o" '.metadata.labels["platform.lab/addon"]' cert-manager
assert_yq "$o" '.metadata.labels["platform.lab/env"]' dev
assert_yq "$o" '.spec.project' platform-workers
assert_yq "$o" '.spec.source.repoURL' 'https://github.com/koorikla/platform-lab.git'
assert_yq "$o" '.spec.source.path' addons/cert-manager       # render-addon's outPath, relative to the branch root
assert_yq "$o" '.spec.destination.name' dev9
assert_yq "$o" '.spec.destination.namespace' cert-manager
# canary ring -> its own branch; a secret without the ring label (created before it existed) counts as stable
o=$(app cert-manager platform.lab/role=worker,platform.lab/env=dev,platform.lab/ring=canary)
branch "$o" dev-canary
o=$(app cert-manager platform.lab/role=worker,platform.lab/env=prod)
branch "$o" prod
assert_yq "$o" '.metadata.labels["platform.lab/env"]' prod
# addon.yaml without namespace: the folder name, as kargo-pipeline defaults it for the render
printf 'addon:\n  name: foo\n' > "$tmp/foo.yaml"
o=$(app foo platform.lab/role=worker,platform.lab/env=dev "$tmp/foo.yaml")
assert_yq "$o" '.spec.destination.namespace' foo
assert_yq "$o" '.spec.source.path' addons/foo
