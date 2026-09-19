#!/usr/bin/env bash
# Remove stale addon folders from Kargo's rendered/* branches: rendered/<b>:addons/<a> goes when
# repos/platform-config/addons/workers/<a>/addon.yaml is not on main (disabled or deleted). Disabling an addon drops its
# Application and its Kargo pipeline, but nothing deletes what the pipeline already rendered: re-enabling it would sync
# those old manifests until the next promotion reaches each stage, and the branch would no longer say what runs.
# Order: disable on main first (the Application goes, preserveResourcesOnDeletion keeps the workload), then prune.
#   hack/rendered-prune.sh            dry run: print what would go
#   hack/rendered-prune.sh --apply    one commit per branch that changes, pushed without force (a concurrent Kargo
#                                     push makes it re-fetch and retry)
# Only addons/ is touched; apps/ belongs to app pipelines. Plumbing only (no worktree, no local branch).
# REMOTE (remote name, path or URL) must be the repo Argo CD pulls; MAIN is the branch Argo reads addon.yaml from.
set -euo pipefail
cd "$(dirname "$0")/.."
remote=${REMOTE:-origin} main=${MAIN:-main} apply=false
case "${1:-}" in
  --apply) apply=true ;;
  "") ;;
  *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac
workers=repos/platform-config/addons/workers

fetch() { git fetch -q --no-tags "$remote" "refs/heads/$1" && git rev-parse FETCH_HEAD; }
main_sha=$(fetch "$main")
enabled=" $(git ls-tree -r --name-only "$main_sha" -- "$workers" |
  sed -n "s#^$workers/\([^/]*\)/addon\.yaml\$#\1#p" | paste -sd' ' -) "
branches=$(git ls-remote --heads "$remote" | awk '{print $2}' | sed -n 's#^refs/heads/\(rendered/.*\)#\1#p')

for b in $branches; do
  for attempt in 1 2 3 4 5; do
    tip=$(fetch "$b")
    if ! git cat-file -e "$tip:addons" 2>/dev/null; then echo "$b: no addons/"; break; fi
    # entries of addons/ ("<mode> <type> <sha>\t<name>"): folders without an enabled addon.yaml are stale
    entries=$(git ls-tree "$tip:addons")
    stale=$(awk -F'\t' -v on="$enabled" '$1 ~ / tree / && index(on, " " $2 " ") == 0 {print $2}' <<<"$entries" |
      paste -sd' ' -)
    if [ -z "$stale" ]; then echo "$b: nothing to prune"; break; fi
    echo "$b: remove $(printf 'addons/%s ' $stale | sed 's/ $//')"
    $apply || break
    keep=$(awk -F'\t' -v drop=" $stale " 'index(drop, " " $2 " ") == 0' <<<"$entries")
    # an empty addons/ would vanish from the branch; the .keep from hack/init-rendered-branches.sh holds it
    [ -n "$keep" ] || keep=$(printf '100644 blob %s\t.keep' "$(git hash-object -w --stdin </dev/null)")
    addons=$(git mktree <<<"$keep")
    root=$( { git ls-tree "$tip" | awk -F'\t' '$2 != "addons"'; printf '040000 tree %s\taddons\n' "$addons"; } |
      git mktree)
    commit=$(git commit-tree "$root" -p "$tip" \
      -m "prune(${b#rendered/}): remove $stale (disabled on main $(git rev-parse --short "$main_sha"))" \
      -m "hack/rendered-prune.sh: no repos/platform-config/addons/workers/<addon>/addon.yaml on $main.")
    if git push -q "$remote" "$commit:refs/heads/$b"; then echo "$b: pushed $commit"; break; fi
    [ "$attempt" -lt 5 ] || { echo "$b: push failed 5 times" >&2; exit 1; }
    echo "$b: push rejected (concurrent render?), retrying" >&2
  done
done
