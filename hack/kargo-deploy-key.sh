#!/usr/bin/env bash
# Kargo's git credential: a write-enabled deploy key scoped to this repo only (can push rendered/* branches and bump
# main; cannot open PRs). Re-run after `make up` on a fresh hub. Replaces any previous kargo deploy key.
# The private key goes straight from a temp file into the hub Secret and is then deleted.
set -euo pipefail
REPO=${REPO:-koorikla/platform-lab} TITLE=kargo-platform-lab NS=kargo-shared-resources CTX=${CTX:-mgmt}

for id in $(gh repo deploy-key list -R "$REPO" --json id,title --jq ".[] | select(.title==\"$TITLE\") | .id"); do
  gh repo deploy-key delete "$id" -R "$REPO"
done

dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C "kargo@$REPO" -f "$dir/key"
gh repo deploy-key add "$dir/key.pub" -R "$REPO" --allow-write -t "$TITLE" >/dev/null

kubectl --context "$CTX" -n "$NS" create secret generic git-platform-lab \
  --from-literal=repoURL="git@github.com:$REPO.git" --from-file=sshPrivateKey="$dir/key" \
  --dry-run=client -o yaml | kubectl --context "$CTX" apply -f - >/dev/null
kubectl --context "$CTX" -n "$NS" label secret git-platform-lab kargo.akuity.io/cred-type=git --overwrite >/dev/null
echo "deploy key '$TITLE' registered on $REPO; secret $NS/git-platform-lab updated"
