#!/usr/bin/env bash
# OpenChoreo platform defaults (#78): addon openchoreo-types (chart openchoreo-app, mode=types) and the pipeline-sync
# script that writes DeploymentPipeline promotionPaths from the fleet's Environments. Chart-local render assertions:
# repos/platform-charts/openchoreo-app/tests/{types,pipeline}_test.yaml (helm-unittest). Here: cross-chart contracts and the script
# against a stubbed kubectl.
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/openchoreo-types
[ "$(yq '.addon.chart' $a/addon.yaml)" = openchoreo-app ] || fail "openchoreo-types must render the openchoreo-app chart"
ns=$(yq '.addon.namespace' $a/addon.yaml)
o=$(render openchoreo-types $charts/openchoreo-app -n "$ns" -f $a/values.yaml)
cj='select(.kind=="CronJob" and .metadata.name=="openchoreo-pipeline-sync")'
envv() { echo "$cj | .spec.jobTemplate.spec.template.spec.containers[0].env[] | select(.name==\"$1\") | .value"; }

# stage order = the Kargo stages every app and addon is promoted through, same names in the same order: the addon's
# pipelineSync.stages is a copy of kargo-pipeline's stages[].name, so drift fails here
stages=$(yq '.stages[].name' $charts/kargo-pipeline/values.yaml | paste -sd' ' -)
[ "$(yq '.pipelineSync.stages | join(" ")' $a/values.yaml)" = "$stages" ] ||
  fail "$a/values.yaml pipelineSync.stages != kargo-pipeline stages ($stages)"
assert_yq "$o" "$(envv STAGES)" "$stages"
# one kubectl+jq pin for Renovate's kubernetes group
assert_yq "$o" "$cj | .spec.jobTemplate.spec.template.spec.containers[0].image" "$(yq .fleetSync.image $charts/openbao/values.yaml)"
# every app's Component is owned by the Project this addon renders (a missing Project keeps Components NotReady)
project=$(yq eval-all 'select(.kind=="Project") | .metadata.name' "$o")
[ -n "$project" ] || fail "openchoreo-types renders no Project"
for f in repos/apps/*/app.yaml; do
  [ "$(yq ".project // \"$(yq .project $charts/openchoreo-app/values.yaml)\"" "$f")" = "$project" ] ||
    fail "$f: project is not the shared Project $project"
done
# Argo must never own promotionPaths (atomic list, written by the CronJob): the rendered pipeline has no spec at all
assert_yq "$o" '[select(.kind=="DeploymentPipeline")] | length' 1
assert_yq "$o" 'select(.kind=="DeploymentPipeline") | has("spec")' false
assert_yq "$o" 'select(.kind=="DeploymentPipeline") | .metadata.name' \
  "$(yq eval-all 'select(.kind=="Project") | .spec.deploymentPipelineRef.name' "$o")"
# the selector finds what the cluster chart renders: Environment <name> with the fleet file's labels
sel=$(yq eval-all "$(envv SELECTOR)" "$o")
e=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml --api-versions openchoreo.dev/v1alpha1/ClusterDataPlane)
assert_yq "$e" "select(.kind==\"Environment\") | .metadata.labels[\"${sel%%=*}\"]" "${sel#*=}"
assert_yq "$e" 'select(.kind=="Environment") | .metadata.labels["platform.lab/env"]' dev
assert_yq "$e" 'select(.kind=="Environment") | .metadata.labels["platform.lab/ring"]' stable
assert_yq "$e" "select(.kind==\"Environment\") | .metadata.namespace" "$(yq eval-all "$(envv NAMESPACE)" "$o")"

script=$tmp/pipeline-sync.sh
yq 'select(.kind=="ConfigMap" and .metadata.name=="openchoreo-pipeline-sync") | .data["pipeline-sync.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "pipeline-sync.sh missing from the ConfigMap"
if command -v shellcheck >/dev/null; then shellcheck -s bash "$script" || fail "shellcheck pipeline-sync.sh"; fi

# stub kubectl: `get environments` prints $STUB_DIR/envs (or fails with $STUB_DIR/fail-get), `patch` records its args
bin=$tmp/bin; mkdir -p "$bin"
cat > "$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$*" in
  "get environments.openchoreo.dev -n default -l platform.lab/role=worker -o json")
    [ ! -f "$STUB_DIR/fail-get" ] || { echo 'Error from server (Forbidden)' >&2; exit 1; }
    cat "$STUB_DIR/envs" ;;
  "patch deploymentpipelines.openchoreo.dev default -n default --type merge --field-manager openchoreo-pipeline-sync -p "*)
    printf '%s' "${@: -1}" > "$STUB_DIR/patch"; echo 'deploymentpipeline.openchoreo.dev/default patched' ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/kubectl"
# env <name> <env> [ring] [terminating]: one Environment as the cluster chart labels it
env_json() {
  jq -n --arg n "$1" --arg e "$2" --arg r "${3:-stable}" --arg t "${4:-}" '{metadata: ({name: $n,
    labels: {"platform.lab/role": "worker", "platform.lab/env": $e, "platform.lab/ring": $r}}
    + (if $t == "" then {} else {deletionTimestamp: "2026-09-19T10:00:00Z"} end))}'
}
run() {  # run <env_json lines...> ; env from $RUN_ENV -> $out, $st, $tmp/patch
  jq -s '{items: .}' <<<"$(printf '%s\n' "$@")" > "$tmp/envs"; : > "$tmp/calls"; rm -f "$tmp/patch"
  set +e
  out=$(env PATH="$bin:$PATH" STUB_DIR="$tmp" NAMESPACE=default PIPELINE=default SELECTOR=platform.lab/role=worker \
    STAGES="$stages" ${RUN_ENV:-} bash "$script" 2>&1); st=$?
  set -e
}
paths() { jq -c '[.spec.promotionPaths[] | {(.sourceEnvironmentRef.name): [.targetEnvironmentRefs[].name]}] | add // {}' "$tmp/patch"; }
has() { grep -q -- "$1" <<<"$out" || fail "expected '$1': $out"; }

# 1. N clusters per env, a canary ring, a terminating Environment, one with a stage Kargo doesn't have
[ "$stages" = "dev-canary dev nit sit prod" ] || fail "script cases below assume the lab's stages, got: $stages"
run "$(env_json dev3 dev)" "$(env_json dev1 dev)" "$(env_json dev2 dev canary)" "$(env_json nit1 nit)" \
  "$(env_json sit1 sit)" "$(env_json prod1 prod)" "$(env_json dev4 dev stable terminating)" "$(env_json test1 test)"
[ "$st" = 1 ] || fail "an Environment outside the Kargo stages must fail the run (exit $st): $out"
[ -f "$tmp/patch" ] || fail "the other Environments must still be written: $out"
# every Environment of a stage -> every Environment of the next non-empty stage; sorted, so reruns are no-ops
[ "$(paths)" = '{"dev2":["dev1","dev3"],"dev1":["nit1"],"dev3":["nit1"],"nit1":["sit1"],"sit1":["prod1"],"prod1":[]}' ] ||
  fail "promotion paths: $(paths)"
[ "$(jq -r '.spec.promotionPaths[0].sourceEnvironmentRef.kind' "$tmp/patch")" = Environment ] || fail "ref kind"
# exactly one root (a source that is never a target): what the Component controller deploys first
[ "$(jq -r '[.spec.promotionPaths[] | .targetEnvironmentRefs[].name] as $t
  | [.spec.promotionPaths[].sourceEnvironmentRef.name | select(. as $s | $t | index($s) | not)] | join(",")' \
  "$tmp/patch")" = dev2 ] || fail "root must be the canary ring"
has '^skipped test1: stage test is not a Kargo stage'
has '^skipped dev4: terminating'
has '^dev-canary: dev2$' && has '^dev: dev1 dev3$' && has '^nit: nit1$' && has '^sit: sit1$'

# 2. the lab today: one worker -> one path without targets (a root, so Components validate)
run "$(env_json dev1 dev)"
[ "$st" = 0 ] || fail "exit $st: $out"
[ "$(paths)" = '{"dev1":[]}' ] || fail "single worker: $(paths)"

# 2b. empty stages in the middle are skipped: dev1 promotes straight to prod1 (one root, not two)
run "$(env_json dev1 dev)" "$(env_json prod1 prod)"
[ "$st" = 0 ] || fail "exit $st: $out"
[ "$(paths)" = '{"dev1":["prod1"],"prod1":[]}' ] || fail "empty middle stages: $(paths)"

# 3. no workers -> no paths (Components stay NotReady: there is nowhere to deploy)
run
[ "$st" = 0 ] || fail "exit $st: $out"
[ "$(jq -c '.spec.promotionPaths' "$tmp/patch")" = '[]' ] || fail "no workers: $(cat "$tmp/patch")"

# 4. a failed read never writes (an empty list would drop every Environment from the pipeline)
touch "$tmp/fail-get"; run "$(env_json dev1 dev)"; rm "$tmp/fail-get"
[ "$st" != 0 ] || fail "failed read must fail the run"
[ ! -f "$tmp/patch" ] || fail "failed read must not patch the pipeline"

# 5. DRY_RUN prints the patch and writes nothing
RUN_ENV=DRY_RUN=1 run "$(env_json dev1 dev)"
[ "$st" = 0 ] || fail "DRY_RUN exit $st: $out"
[ ! -f "$tmp/patch" ] || fail "DRY_RUN must not patch"
has 'DRY_RUN: .*"promotionPaths"'
