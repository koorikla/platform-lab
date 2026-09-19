#!/usr/bin/env bash
# Kargo verification (#26): every addon stage runs AnalysisTemplate argocd-apps after a promotion. Its Job checks that
# the stage's hub Applications (worker-addons labels addon + env + ring) are Synced + Healthy at the promoted rendered
# commit (or a later commit of rendered/<stage>); Freight moves on only once that held for a few measurements.
source "$(dirname "$0")/lib.sh"
stage() { echo "select(.kind==\"Stage\" and .metadata.name==\"$1\")"; }
arg() { echo "$(stage "$1") | .spec.verification.args[] | select(.name==\"$2\") | .value"; }
o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager)
at='select(.kind=="AnalysisTemplate")'
job="$at | .spec.metrics[0].provider.job.spec"

# every stage verifies with the project's template; args say which Applications and which commit
assert_yq "$o" '[select(.kind=="Stage") | .spec.verification.analysisTemplates | map(.name) | join(",")] | unique | join(";")' argocd-apps
assert_yq "$o" "$at | .metadata.namespace" addon-cert-manager
for s in dev-canary dev nit sit prod; do
  assert_yq "$o" "$(arg $s branch)" "$s"
  assert_yq "$o" "$(arg $s env)" "$(yq ".stages[] | select(.name==\"$s\") | .env" $charts/kargo-pipeline/values.yaml)"
done
# ring: same rule as the worker-addons appset (a <env>-canary branch <=> ring canary)
assert_yq "$o" "$(arg dev-canary ring)" canary
assert_yq "$o" "[$(arg dev ring), $(arg nit ring), $(arg sit ring), $(arg prod ring)] | join(\",\")" stable,stable,stable,stable
# the promoted rendered commit: the render task's output, recorded on the Stage by the step after it (verification
# can't read promotion outputs, only Stage metadata)
assert_yq "$o" "[select(.kind==\"Stage\") | .spec.promotionTemplate.spec.steps[1]] | map(.uses) | unique | join(\",\")" set-metadata
for s in dev-canary prod; do
  assert_yq "$o" "$(stage $s) | .spec.promotionTemplate.spec.steps[1].config.updates[0] | .kind + \"/\" + .name" "Stage/$s"
  # quote(): a SHA of digits (and one e) would otherwise come back from Kargo's evaluator as a number
  assert_yq "$o" "$(stage $s) | .spec.promotionTemplate.spec.steps[1].config.updates[0].values.renderedCommit" '${{ quote(outputs.render.commit) }}'
done
assert_yq "$o" "$(arg dev revision)" '${{ quote(stageMetadata(ctx.stage)?.renderedCommit ?? "") }}'
# an empty canary ring must not open the gate for the next stage; other empty stages pass
assert_yq "$o" "$(arg dev-canary requireApps)" true
assert_yq "$o" "[$(arg dev requireApps), $(arg nit requireApps), $(arg sit requireApps), $(arg prod requireApps)]
  | join(\",\")" false,false,false,false
# Kargo v1.11.4 silently drops a Stage arg the template doesn't declare, and fails the run for a declared arg without
# a value: both lists must be equal
assert_yq "$o" "$at | .spec.args | map(.name) | sort | join(\",\")" \
  "$(yq eval-all "$(stage dev) | .spec.verification.args | map(.name) | sort | join(\",\")" "$o")"

# measurement = one Job; wait for convergence, then require consecutive successes; give up after count
m="$at | .spec.metrics[0]"
assert_yq "$o" "$m | .failureLimit" -1
assert_yq "$o" "$m | .consecutiveSuccessLimit > 1" true
assert_yq "$o" "$m | .count > .consecutiveSuccessLimit" true
assert_yq "$o" "$m | .interval | test(\"^[0-9]+[sm]\$\")" true
assert_yq "$o" "$job | .backoffLimit" 0
assert_yq "$o" "$job | .activeDeadlineSeconds > 0" true
assert_yq "$o" "$job | .template.spec.serviceAccountName" verify-apps
# same kubectl+git+jq image as fleet-sync (one pin for Renovate's kubernetes group)
assert_yq "$o" "$job | .template.spec.containers[0].image" \
  "$(yq .fleetSync.image $charts/openbao/values.yaml)"
envv() { echo "$job | .template.spec.containers[0].env[] | select(.name==\"$1\") | .value"; }
assert_yq "$o" "$(envv ADDON)" cert-manager
assert_yq "$o" "$(envv ARGOCD_NS)" argocd
assert_yq "$o" "$(envv REPO_URL)" https://github.com/koorikla/platform-lab.git
for a in env:ENV ring:RING branch:BRANCH revision:REVISION requireApps:REQUIRE_APPS; do
  assert_yq "$o" "$(envv "${a#*:}")" "{{args.${a%%:*}}}"
done
# every declared arg reaches the Job
assert_yq "$o" "[$at | .spec.args[].name | \"{{args.\" + . + \"}}\"] - [$job | .template.spec.containers[0].env[].value] | length" 0
# the rendered branches the Job reads are the ones Argo syncs (worker-addons appset source)
assert_yq "$o" "$(envv REPO_URL)" "$(yq .spec.template.spec.source.repoURL $config/argocd/appset-worker-addons.yaml)"
assert_yq "$o" "$job | .template.spec.securityContext.runAsNonRoot" true
assert_yq "$o" "$job | .template.spec.containers[0].securityContext.readOnlyRootFilesystem" true

# least privilege: the Job's SA may only read Applications in argocd
assert_yq "$o" 'select(.kind=="ServiceAccount") | .metadata.namespace + "/" + .metadata.name' addon-cert-manager/verify-apps
assert_yq "$o" '[select(.kind=="Role" or .kind=="ClusterRole" or .kind=="RoleBinding" or .kind=="ClusterRoleBinding") | .kind + ":" + .metadata.namespace] | join(",")' Role:argocd,RoleBinding:argocd
assert_yq "$o" 'select(.kind=="Role") | .rules | map(.apiGroups[] + "/" + (.resources | join("+")) + ":" + (.verbs | join("+"))) | join(",")' \
  argoproj.io/applications:get+list
assert_yq "$o" 'select(.kind=="RoleBinding") | .roleRef.kind + "/" + .roleRef.name' \
  "Role/$(yq eval-all 'select(.kind=="Role") | .metadata.name' "$o")"
assert_yq "$o" 'select(.kind=="RoleBinding") | .subjects | map(.kind + ":" + .namespace + "/" + .name) | join(",")' \
  ServiceAccount:addon-cert-manager/verify-apps
# two addons don't fight over one RBAC object in argocd
k=$(render p $charts/kargo-pipeline --set name=kgateway)
[ "$(yq eval-all 'select(.kind=="Role") | .metadata.name' "$k")" != "$(yq eval-all 'select(.kind=="Role") | .metadata.name' "$o")" ] ||
  fail "Role name in argocd must be per project"

# the selector's labels are exactly what worker-addons stamps on each Application
script=$tmp/verify-apps.sh
yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="verify-apps") | .data["verify-apps.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "verify-apps.sh missing from the ConfigMap"
assert_yq "$o" "$job | .template.spec.volumes[] | select(.name==\"script\") | .configMap.name" verify-apps
for l in addon env ring; do
  [ "$(yq ".spec.template.metadata.labels | has(\"platform.lab/$l\")" $config/argocd/appset-worker-addons.yaml)" = true ] ||
    fail "worker-addons Applications lack label platform.lab/$l"
  grep -q "platform.lab/$l=" "$script" || fail "verify-apps.sh doesn't select on platform.lab/$l"
done
if command -v shellcheck >/dev/null; then shellcheck -s bash "$script" || fail "shellcheck verify-apps.sh"; fi

# --- the script against stubs: kubectl returns $STUB_DIR/apps.json, git knows the ancestry in $STUB_DIR/ancestry
bin=$tmp/bin; mkdir -p "$bin"
cat > "$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_DIR/calls"
case "$*" in
  "get applications.argoproj.io -n argocd -l platform.lab/addon=cert-manager,platform.lab/env=dev,platform.lab/ring=canary -o json")
    cat "$STUB_DIR/apps.json" ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
STUB
cat > "$bin/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$STUB_DIR/calls"
case "$*" in
  *" fetch "*) [ ! -e "$STUB_DIR/fetch_fails" ] || exit 128 ;;
  *" merge-base --is-ancestor "*) grep -qx "${*: -2:1} ${*: -1}" "$STUB_DIR/ancestry" ;;   # "<old> <new>" lines
  *" init "*|"init "*) ;;
  *) echo "unexpected git $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/kubectl" "$bin/git"
app() {  # app <name> <sync> <health> <revision>
  printf '{"metadata":{"name":"%s"},"status":{"sync":{"status":"%s","revision":"%s"},"health":{"status":"%s"}}}' "$1" "$2" "$4" "$3"
}
run() {  # run <revision> <app json>... -> $out, $st; calls in $tmp/calls. $REQ = REQUIRE_APPS (default false)
  local rev=$1; shift
  printf '{"items":[%s]}' "$(IFS=,; echo "$*")" > "$tmp/apps.json"; : > "$tmp/calls"
  set +e
  out=$(env -i PATH="$bin:$PATH" HOME="$tmp/home" STUB_DIR="$tmp" ADDON=cert-manager ENV=dev RING=canary BRANCH=dev-canary \
        REVISION="$rev" REQUIRE_APPS="${REQ:-false}" REPO_URL=https://example.invalid/lab.git ARGOCD_NS=argocd \
        bash "$script" 2>&1)
  st=$?; set -e
}
ok()   { [ "$st" = 0 ] || fail "line ${BASH_LINENO[0]}: want success, got $st: $out"; }
nok()  { [ "$st" != 0 ] || fail "line ${BASH_LINENO[0]}: want failure: $out"; }
has()  { grep -q -- "$1" <<<"$out" || fail "line ${BASH_LINENO[0]}: expected '$1' in: $out"; }
nogit() { ! grep -q '^git' "$tmp/calls" || fail "line ${BASH_LINENO[0]}: git called although not needed"; }
mkdir -p "$tmp/home"; : > "$tmp/ancestry"
R=aaaaaaa1111111111111111111111111111111a

# no clusters in the stage (nit/sit/prod today): nothing to verify, passes
run "$R"
ok; has 'no Applications'; nogit
# ...also before any promotion recorded a commit (the stage's first verification after this change)
run ""
ok
# a canary stage (REQUIRE_APPS=true) without Applications fails: an empty ring must not let dev follow
REQ=true run "$R"
nok; has 'requires some'
REQ=true run "$R" "$(app cert-manager-dev2 Synced Healthy $R)"
ok
# all at the promoted commit
run "$R" "$(app cert-manager-dev2 Synced Healthy $R)" "$(app cert-manager-dev3 Synced Healthy $R)"
ok; has '^OK.*cert-manager-dev2' && has '^OK.*cert-manager-dev3'; nogit
# one still progressing / out of sync / never reported: wait (measurement fails, the run retries)
run "$R" "$(app cert-manager-dev2 Synced Healthy $R)" "$(app cert-manager-dev3 Synced Progressing $R)"
nok; has '^WAIT.*cert-manager-dev3.*Progressing'
run "$R" "$(app cert-manager-dev2 OutOfSync Healthy $R)"
nok; has '^WAIT.*cert-manager-dev2.*OutOfSync'
run "$R" '{"metadata":{"name":"cert-manager-dev2"}}'
nok; has '^WAIT.*cert-manager-dev2'
# Healthy at an older commit (the worker hasn't polled rendered/<stage> yet, or the agent is disconnected and the hub
# shows stale status): not verified
run "$R" "$(app cert-manager-dev2 Synced Healthy bbbbbbb)"
nok; has "^WAIT.*cert-manager-dev2.*bbbbbbb.*$R"
grep -q "git .*fetch .*https://example.invalid/lab.git .*rendered/dev-canary" "$tmp/calls" || fail "fetch of rendered/dev-canary: $(cat "$tmp/calls")"
# another addon's promotion pushed on top of ours: a later commit that contains ours counts
echo "$R ccccccc" > "$tmp/ancestry"
run "$R" "$(app cert-manager-dev2 Synced Healthy ccccccc)" "$(app cert-manager-dev3 Synced Healthy ccccccc)"
ok; [ "$(grep -c ' fetch ' "$tmp/calls")" = 1 ] || fail "fetch once per measurement: $(cat "$tmp/calls")"
# the history can't be fetched: fail this measurement, never pass it
touch "$tmp/fetch_fails"
run "$R" "$(app cert-manager-dev2 Synced Healthy ccccccc)"
nok; rm "$tmp/fetch_fails"
# Applications exist but no commit was recorded (promoted before this change): fail with a hint, don't guess
run "" "$(app cert-manager-dev2 Synced Healthy $R)"
nok; has 'renderedCommit'
# only reads: the Job never writes to the hub
! grep -qE '^kubectl (apply|patch|delete|create|annotate|label|edit|replace)' "$tmp/calls" || fail "script mutates: $(cat "$tmp/calls")"
