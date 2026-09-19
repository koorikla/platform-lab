#!/usr/bin/env bash
# PR guard (ci.yaml): every chart in repos/platform-charts/ whose files changed since <base-ref> must change its
# Chart.yaml version. charts.yaml publishes only versions GHCR doesn't have yet, so an unbumped change would never
# reach the registry (and CAAPH/Argo pinned to that version would keep the old content).
# Compares the merge-base with the working tree: commits on the branch and uncommitted edits count, base-only commits
# don't. New charts pass (nothing to bump against), deleted charts pass (nothing to publish), and so do changes only
# to a chart's root tests/ when its .helmignore keeps them out of the package (`/tests/`).
# usage: hack/check-chart-versions.sh origin/main
set -euo pipefail
base=${1:?usage: $0 <base-ref>}
cd "$(git rev-parse --show-toplevel)"
charts=repos/platform-charts
mb=$(git merge-base "$base" HEAD)
rc=0
# charts with a changed file; a chart's helm-unittest suites (tests/) are not packaged when its .helmignore says so,
# so changing only them publishes nothing new and needs no bump
changed=$(git diff --name-only --no-renames "$mb" -- "$charts" | while read -r f; do
  c=$(cut -d/ -f1-3 <<<"$f")
  if [[ $f == "$c"/tests/* ]] && grep -qx '/tests/' "$c/.helmignore" 2>/dev/null; then continue; fi
  echo "$c"
done | sort -u)
for c in $changed; do
  [ -f "$c/Chart.yaml" ] || continue                           # deleted chart, or a file directly in $charts
  git cat-file -e "$mb:$c/Chart.yaml" 2>/dev/null || continue  # new chart
  old=$(git show "$mb:$c/Chart.yaml" | yq '.version')
  new=$(yq '.version' "$c/Chart.yaml")
  if [ "$old" = "$new" ]; then
    echo "FAIL: $c changed since $base but its Chart.yaml version is still $new: bump it" >&2
    rc=1
  fi
done
[ "$rc" -ne 0 ] || echo "chart versions: OK"
exit "$rc"
