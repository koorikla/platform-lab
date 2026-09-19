#!/usr/bin/env bash
# hack/publish-charts.sh (charts.yaml) against a stub helm: skip published versions, never push on an ambiguous or
# failed existence check, retry before trusting "denied", DRY_RUN never pushes. Uses the real chart dirs.
source "$(dirname "$0")/lib.sh"
pub=$PWD/hack/publish-charts.sh
if command -v shellcheck >/dev/null; then shellcheck "$pub" || fail "shellcheck publish-charts.sh"; fi
# the guard keys on the chart dir, publishing on .name: they must agree
for c in $charts/*/; do
  [ "$(yq '.name' "$c/Chart.yaml")" = "$(basename "$c")" ] || fail "$c: Chart.yaml name != dir name"
done
n=$(find $charts -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')

# stub: $STUB_DIR/show.<chart> = one answer per `helm show chart` attempt (last one repeats), default notfound
bin=$tmp/bin; mkdir -p "$bin"
cat > "$bin/helm" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/calls"
case "$1 $2" in
  "show chart")
    name=$(basename "$3"); f=$STUB_DIR/show.$name; c=$STUB_DIR/count.$name
    i=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 )); echo "$i" > "$c"
    ans=notfound; [ ! -f "$f" ] || ans=$(sed -n "${i}p" "$f"); [ -n "$ans" ] || ans=$(tail -n1 "$f")
    case $ans in
      published) echo "name: $name" ;;
      notfound) echo "Error: failed to perform \"FetchReference\" on source: ${3#oci://}:$5: not found" >&2; exit 1 ;;
      denied) echo "Error: failed to perform \"FetchReference\" on source: GET \"https://x/token\": response status code 403: denied: requested access to the resource is denied" >&2; exit 1 ;;
      *) echo "Error: failed to perform \"FetchReference\" on source: response status code 502: Bad Gateway" >&2; exit 1 ;;
    esac ;;
  "package "*) touch "$4/$(yq '.name' "$2/Chart.yaml")-$(yq '.version' "$2/Chart.yaml").tgz" ;;
esac
STUB
chmod +x "$bin/helm"
run() {  # run <stub dir> [env...] -> output in <stub dir>/out, exit code returned
  local d=$1; shift
  env PATH="$bin:$PATH" STUB_DIR="$d" SHOW_PAUSE=0 "$@" bash "$pub" oci://reg.example/charts > "$d/out" 2>&1
}
pushes() { grep -c '^push ' "$1/calls" || true; }
shows() { grep -c "^show chart oci://reg.example/charts/$2 " "$1/calls" || true; }

# DRY_RUN: packages everything, pushes nothing, one existence check per chart
d=$tmp/dry; mkdir -p "$d"
run "$d" DRY_RUN=1 || fail "dry run failed: $(cat "$d/out")"
[ "$(pushes "$d")" = 0 ] || fail "DRY_RUN pushed"
[ "$(grep -c '^package ' "$d/calls")" = "$n" ] || fail "DRY_RUN must package all $n charts"
[ "$(grep -c '^would push ' "$d/out")" = "$n" ] || fail "DRY_RUN must report all $n charts"
[ "$(shows "$d" argo-cd)" = 1 ] || fail "not found must not be retried"

# publish: published -> skip; not found -> push; denied survives retries -> push, logged; denied then published -> skip
d=$tmp/pub; mkdir -p "$d"
echo published > "$d/show.argo-cd"
echo denied > "$d/show.cluster"
printf 'denied\npublished\n' > "$d/show.kargo"
run "$d" || fail "publish failed: $(cat "$d/out")"
grep -q '^push .*/argo-cd-[0-9]' "$d/calls" && fail "published argo-cd was pushed again"
grep -q '^push .*/kargo-[0-9]' "$d/calls" && fail "kargo pushed although the retry found it published"
grep -q '^push .*/cert-manager-0.1.0.tgz oci://reg.example/charts$' "$d/calls" || fail "cert-manager (not found) not pushed"
grep -q '^push .*/cluster-[0-9]' "$d/calls" || fail "cluster (denied every time) not pushed"
[ "$(shows "$d" cluster)" = 3 ] || fail "denied must be retried (3 attempts), got $(shows "$d" cluster)"
[ "$(pushes "$d")" = $((n - 2)) ] || fail "want $((n - 2)) pushes, got $(pushes "$d")"
grep -q '^push cluster:.*registry said:.*403: denied' "$d/out" || fail "the registry's answer must be logged: $(grep cluster "$d/out")"
grep -q '^skip argo-cd:' "$d/out" || fail "skip not logged"

# any other registry error stops the run before anything is pushed (argo-cd is the first chart)
d=$tmp/err; mkdir -p "$d"
echo 502 > "$d/show.argo-cd"
if run "$d"; then fail "registry error must fail the publish"; fi
[ "$(pushes "$d")" = 0 ] || fail "pushed after a registry error"
[ "$(shows "$d" argo-cd)" = 3 ] || fail "registry errors must be retried"
grep -q 'FAIL: .*argo-cd.*502' "$d/out" || fail "error not reported: $(cat "$d/out")"
# ... but only warns in DRY_RUN (PR CI must not depend on GHCR's mood)
d=$tmp/dryerr; mkdir -p "$d"
echo 502 > "$d/show.argo-cd"
run "$d" DRY_RUN=1 || fail "DRY_RUN must not fail on registry errors"
[ "$(pushes "$d")" = 0 ] || fail "DRY_RUN pushed"
