# hack/tests/lib.sh — sourced by every test_*.sh. Render with helm, assert with yq.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
charts=repos/platform-charts
config=repos/platform-config
# renders go to one temp dir owned by the test process (render runs in $(...) subshells, so it can't trap itself)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# assert_yq <file> <yq-expression> <expected>; eval-all so [select(...)] spans every document of the render
assert_yq() { local got; got=$(yq eval-all "$2" "$1"); [ "$got" = "$3" ] || fail "$1: $2 = '$got', want '$3'"; }
# render <helm template args...> -> path of the rendered multi-doc file; `|| fail` because errexit is off inside $(...)
render() { local out; out=$(mktemp "$tmp/render.XXXXXX"); helm template "$@" > "$out" || fail "helm template $*"; echo "$out"; }
