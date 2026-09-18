# hack/tests/lib.sh — sourced by every test_*.sh. Render with helm, assert with yq.
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
# render <release> <chart> [helm args...] -> path of the rendered multi-doc file.
# Assign it first (x=$(render ...)): `local x=$(...)` or an inline $(render) swallows its exit code.
render() {
  local out a
  out=$(mktemp "$tmp/$1.XXXXXX")
  # umbrella charts: charts/*.tgz are gitignored, so build them (fast once helm's cache is warm)
  for a in "${@:2}"; do
    if [ -f "$a/Chart.yaml" ]; then
      ! grep -q '^dependencies:' "$a/Chart.yaml" || helm dependency build "$a" >/dev/null || fail "helm dependency build $a"
      break
    fi
  done
  # `|| fail` because errexit is off inside $(...)
  helm template "$@" > "$out" || fail "helm template $*"
  echo "$out"
}
