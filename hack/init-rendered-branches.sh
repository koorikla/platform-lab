#!/usr/bin/env bash
# Orphan branches rendered/<env>, written only by Kargo (rendered manifests pattern). Idempotent; Argo references them
# from day one. Plumbing only: no worktree, no local branch, no minimum git version.
# REMOTE (remote name, path or URL) must be the repo Argo CD pulls, i.e. the repoURL in bootstrap/root-app.yaml.
set -euo pipefail
cd "$(dirname "$0")/.."
remote=${REMOTE:-origin}
keep=$(git hash-object -w --stdin </dev/null)
keep_tree=$(printf '100644 blob %s\t.keep\n' "$keep" | git mktree)
for b in dev-canary dev test prod; do
  rc=0; git ls-remote --exit-code --heads "$remote" "refs/heads/rendered/$b" >/dev/null || rc=$?
  case $rc in
    0) continue ;;   # exists: never touch it, Kargo owns it
    2) ;;            # missing: create below
    *) echo "git ls-remote $remote failed (exit $rc)" >&2; exit 1 ;;
  esac
  readme=$(printf '# rendered/%s\nWritten only by Kargo (rendered manifests pattern). Do not edit.\n' "$b" |
    git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\tREADME.md\n040000 tree %s\taddons\n040000 tree %s\tapps\n' \
    "$readme" "$keep_tree" "$keep_tree" | git mktree)
  commit=$(git commit-tree "$tree" -m "init rendered/$b")
  git push -q "$remote" "$commit:refs/heads/rendered/$b"
  echo "created rendered/$b ($commit)"
done
