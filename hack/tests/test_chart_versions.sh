#!/usr/bin/env bash
# hack/check-chart-versions.sh (PR guard, ci.yaml): a chart whose files changed vs the base ref must bump its
# Chart.yaml version, else charts.yaml skips it (that version already exists in GHCR). Runs in a throwaway git repo.
source "$(dirname "$0")/lib.sh"
check=$PWD/hack/check-chart-versions.sh
if command -v shellcheck >/dev/null; then shellcheck "$check" || fail "shellcheck check-chart-versions.sh"; fi
# the guard only helps if CI runs it on PRs
assert_yq .github/workflows/ci.yaml '[.jobs[].steps[] | select(.run // "" | test("hack/check-chart-versions.sh"))] | length' 1

repo=$tmp/repo; mkdir -p "$repo"; cd "$repo"
g() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@" >/dev/null; }
chart() { mkdir -p "repos/platform-charts/$1/templates"; printf 'apiVersion: v2\nname: %s\nversion: %s\n' "$1" "$2" > "repos/platform-charts/$1/Chart.yaml"; }
g init -q -b main
chart a 0.1.0; chart b 0.1.0; chart d 0.1.0; echo x > repos/platform-charts/d/values.yaml; echo x > repos/platform-charts/a/values.yaml; echo docs > README.md
g add -A; g commit -qm base
g checkout -qb pr

bash "$check" main >/dev/null || fail "no changes must pass"
echo y > README.md; g commit -qam "outside charts"
bash "$check" main >/dev/null || fail "changes outside charts must pass"

echo y > repos/platform-charts/a/values.yaml; g commit -qam "a changed"
out=$(bash "$check" main 2>&1) && fail "changed chart without version bump must fail"
grep -q 'repos/platform-charts/a' <<<"$out" || fail "failure must name chart a: $out"
! grep -q 'platform-charts/b' <<<"$out" || fail "unchanged chart b must not be reported: $out"
# uncommitted edits count too (local use before committing)
sed -i.bak 's/^version: .*/version: 0.1.1/' repos/platform-charts/a/Chart.yaml && rm repos/platform-charts/a/Chart.yaml.bak
bash "$check" main >/dev/null || fail "bumped (uncommitted) chart must pass"
g commit -qam "a bumped"
bash "$check" main >/dev/null || fail "bumped chart must pass"

# a new chart has nothing to bump against; a deleted chart has nothing to publish
chart c 0.1.0; g add -A; g commit -qm "new chart c"
g rm -rq repos/platform-charts/b; g commit -qm "b deleted"
bash "$check" main >/dev/null || fail "new/deleted charts must pass"

# base moved on after the branch point: only this branch's changes count (merge-base)
g checkout -q main; echo z > repos/platform-charts/d/values.yaml; g commit -qam "d changed on main"
g checkout -q pr
bash "$check" main >/dev/null || fail "changes that only happened on the base must not be blamed on the branch"

assert_fails bash "$check"                 # base ref is required
assert_fails bash "$check" no-such-ref
