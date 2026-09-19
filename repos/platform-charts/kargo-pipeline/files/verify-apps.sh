#!/usr/bin/env bash
# One measurement of Kargo verification (AnalysisTemplate argocd-apps): the hub Applications of this addon on this
# stage's clusters (worker-addons labels addon + env + ring; status mirrored from the workers by argocd-agent) must be
# Synced + Healthy at the promoted rendered commit REVISION, or at a later commit of rendered/BRANCH that contains it
# (every addon pipeline pushes to the same branch). Exit 0 = measurement Successful. Read-only on the hub.
# No matching Applications (no clusters in this stage, e.g. nit/sit/prod today) = nothing to verify = success, unless
# REQUIRE_APPS=true (canary stages: an empty canary ring proves nothing and must not open the gate for the next stage).
set -euo pipefail
: "${ADDON:?}" "${ENV:?}" "${RING:?}" "${BRANCH:?}" "${REPO_URL:?}" "${ARGOCD_NS:?}" "${HOME:?}"
REVISION=${REVISION:-}
REQUIRE_APPS=${REQUIRE_APPS:-false}
sel="platform.lab/addon=$ADDON,platform.lab/env=$ENV,platform.lab/ring=$RING"

apps=$(kubectl get applications.argoproj.io -n "$ARGOCD_NS" -l "$sel" -o json | jq -r '.items[] | [.metadata.name,
  .status.sync.status // "Unknown", .status.health.status // "Unknown", .status.sync.revision // "none"] | @tsv')
if [ -z "$apps" ]; then
  if [ "$REQUIRE_APPS" = true ]; then
    echo "no Applications match $sel, but this stage requires some (canary ring without clusters?): not verified"
    exit 1
  fi
  echo "no Applications match $sel: no clusters in this stage, nothing to verify"
  exit 0
fi
if [ -z "$REVISION" ]; then
  echo "Stage status.metadata.renderedCommit is empty (Freight promoted before verification existed?): promote again"
  exit 1
fi

# contains <rev>: <rev> is REVISION or a descendant on rendered/BRANCH. History fetched once, commits only.
fetched=
contains() {
  [ "$1" = "$REVISION" ] && return 0
  if [ -z "$fetched" ]; then
    git init -q "$HOME/rendered"
    git -C "$HOME/rendered" fetch -q --no-tags --filter=tree:0 "$REPO_URL" "refs/heads/rendered/$BRANCH" ||
      { echo "cannot fetch rendered/$BRANCH from $REPO_URL"; exit 1; }
    fetched=1
  fi
  git -C "$HOME/rendered" merge-base --is-ancestor "$REVISION" "$1" 2>/dev/null
}

rc=0
while IFS=$'\t' read -r name sync health rev; do
  if [ "$sync" != Synced ] || [ "$health" != Healthy ]; then
    echo "WAIT $name: $sync/$health at $rev"; rc=1
  elif ! contains "$rev"; then
    echo "WAIT $name: Synced/Healthy at $rev, which does not contain $REVISION (yet)"; rc=1
  else
    echo "OK   $name: Synced/Healthy at $rev"
  fi
done <<<"$apps"
exit $rc
