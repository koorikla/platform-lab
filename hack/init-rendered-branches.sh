#!/usr/bin/env bash
# Orphan branches written only by Kargo. Idempotent. Argo references them from day one.
set -euo pipefail
cd "$(dirname "$0")/.."
for b in dev-canary dev test prod; do
  git ls-remote --exit-code --heads origin "rendered/$b" >/dev/null && continue
  tmp=$(mktemp -d); git worktree add --orphan -b "rendered/$b" "$tmp" >/dev/null
  printf '# rendered/%s\nWritten only by Kargo (rendered manifests pattern). Do not edit.\n' "$b" > "$tmp/README.md"
  mkdir -p "$tmp/addons" "$tmp/apps" && touch "$tmp/addons/.keep" "$tmp/apps/.keep"
  git -C "$tmp" add -A && git -C "$tmp" commit -qm "init rendered/$b" && git -C "$tmp" push -q origin "rendered/$b"
  git worktree remove "$tmp"
done
