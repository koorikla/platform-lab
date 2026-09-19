#!/usr/bin/env bash
# Kargo verification (#26): every addon stage runs AnalysisTemplate argocd-apps after a promotion. Its Job checks that
# the stage's hub Applications (worker-addons labels addon + env + ring) are Synced + Healthy at the promoted rendered
# commit (or a later commit of rendered/<stage>); Freight moves on only once that held for a few measurements.
# Template, Job, args and RBAC: kargo-pipeline unit tests (tests/verification_test.yaml). Here: what the Job shares
# with the rest of the repo (image pin, the repo and labels worker-addons uses), then verify-apps.sh against stubs.
source "$(dirname "$0")/lib.sh"
o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager)
job='select(.kind=="AnalysisTemplate") | .spec.metrics[0].provider.job.spec'
envv() { echo "$job | .template.spec.containers[0].env[] | select(.name==\"$1\") | .value"; }
# same kubectl+git+jq image as fleet-sync (one pin for Renovate's kubernetes group)
assert_yq "$o" "$job | .template.spec.containers[0].image" "$(yq .fleetSync.image $charts/openbao/values.yaml)"
# the rendered branches the Job reads are the ones Argo syncs (worker-addons appset source)
assert_yq "$o" "$(envv REPO_URL)" "$(yq .spec.template.spec.source.repoURL $config/argocd/appset-worker-addons.yaml)"

# the selector's labels are exactly what worker-addons stamps on each Application
script=$tmp/verify-apps.sh
yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="verify-apps") | .data["verify-apps.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "verify-apps.sh missing from the ConfigMap"
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
