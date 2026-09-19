# hack/tests/lib.sh — sourced by every test_*.sh. Render with helm, assert with yq.
# shellcheck shell=bash disable=SC2034  # charts/config/tmp are for the sourcing tests
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
charts=repos/platform-charts
config=repos/platform-config
fail() { echo "FAIL: $*" >&2; exit 1; }
# python-yq has a different syntax and would give confusing mismatches instead of a clear error
yq --version 2>&1 | grep -q mikefarah || fail "need mikefarah yq v4 on PATH"
# renders go to one temp dir owned by the test process (render runs in $(...) subshells, so it can't trap itself).
# Don't set your own EXIT trap in a test: it replaces this cleanup.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# assert_yq <file> <yq-expression> <expected>; eval-all so [select(...)] spans every document of the render.
# A missing field yields 'null'; an expression matching no document yields ''.
assert_yq() {
  local got
  got=$(yq eval-all "$2" "$1") || fail "line ${BASH_LINENO[0]}: yq failed: $2"
  [ "$got" = "$3" ] || fail "line ${BASH_LINENO[0]}: $2 = '$got', want '$3'"
}
# assert_fails <cmd...>: the command must exit non-zero (e.g. a render the chart has to reject)
assert_fails() {
  if "$@" >/dev/null 2>&1; then fail "line ${BASH_LINENO[0]}: expected failure: $*"; fi
}
# deps <chart dir>: umbrella charts' charts/*.tgz are gitignored, so build them (fast once helm's cache is warm)
deps() {
  ! grep -q '^dependencies:' "$1/Chart.yaml" || helm dependency build "$1" >/dev/null || fail "helm dependency build $1"
}
# render <release> <chart> [helm args...] -> path of the rendered multi-doc file.
# Assign it first (x=$(render ...)): `local x=$(...)` or an inline $(render) swallows its exit code.
render() {
  local out a
  out=$(mktemp "$tmp/$1.XXXXXX")
  for a in "${@:2}"; do
    if [ -f "$a/Chart.yaml" ]; then deps "$a"; break; fi
  done
  # `|| fail` because errexit is off inside $(...)
  helm template "$@" > "$out" || fail "helm template $*"
  echo "$out"
}
# gotpl <template string> <context yaml file> -> the rendered string. ApplicationSets can't be rendered offline: this
# executes a template with helm's `tpl` (text/template + sprig, like the appset controller) against params shaped like
# the generators' output. Not covered: missingkey behaviour (helm's tpl runs missingkey=zero).
gotpl() {
  if [ ! -f "$tmp/tpl/Chart.yaml" ]; then
    mkdir -p "$tmp/tpl/templates"
    printf 'apiVersion: v2\nname: tpl\nversion: 0.0.0\n' > "$tmp/tpl/Chart.yaml"
    echo 'out: {{ tpl .Values.t .Values.ctx | toJson }}' > "$tmp/tpl/templates/out.yaml"   # helm wants a mapping
  fi
  printf '%s' "$1" > "$tmp/t.txt"
  yq -n ".ctx = load(\"$2\")" > "$tmp/ctx.yaml"
  helm template tpl "$tmp/tpl" -f "$tmp/ctx.yaml" --set-file t="$tmp/t.txt" | yq -N '.out' ||
    fail "gotpl: $1"
}
