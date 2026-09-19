#!/usr/bin/env bash
# hack/rendered-prune.sh against a throw-away bare remote: removes rendered/*:addons/<a> whose
# addons/workers/<a>/addon.yaml is not enabled on main, touches nothing else, dry run by default, idempotent.
source "$(dirname "$0")/lib.sh"
prune=$PWD/hack/rendered-prune.sh
remote=$tmp/remote.git
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
git init -q --bare "$remote"
# GIT_DIR: the script's scratch object store, so the test writes nothing into this repo
git init -q --bare "$tmp/scratch.git"
run() { GIT_DIR=$tmp/scratch.git REMOTE=$remote "$prune" "$@"; }

# seed <branch> <file>... : force <branch> of the remote to one commit holding exactly these files
seed() {
  local w=$tmp/seed-$1 b=$1; shift
  rm -rf "$w"; git init -q "$w"
  for f in "$@"; do mkdir -p "$w/$(dirname "$f")"; echo "# $f" > "$w/$f"; done
  git -C "$w" add -A; git -C "$w" commit -qm "seed $b"; git -C "$w" push -qf "$remote" "HEAD:refs/heads/$b"
}
files() { git --git-dir="$remote" ls-tree -r --name-only "$1" | paste -sd, -; }
tip() { git --git-dir="$remote" rev-parse "$1"; }
cfg=repos/platform-config/addons/workers
seed main $cfg/cert-manager/addon.yaml $cfg/kgateway/addon.yaml.disabled $cfg/kgateway/values.yaml
seed rendered/dev README.md addons/.keep apps/.keep apps/podinfo/x.yaml \
  addons/cert-manager/a.yaml addons/kgateway/b.yaml addons/external-secrets/c.yaml
seed rendered/prod README.md addons/.keep apps/.keep addons/cert-manager/a.yaml
dev0=$(tip rendered/dev) prod0=$(tip rendered/prod)

# dry run by default
out=$(run) || fail "dry run failed"
grep -q '^rendered/dev: remove addons/external-secrets addons/kgateway$' <<<"$out" || fail "dry run output: $out"
[ "$(tip rendered/dev)" = "$dev0" ] || fail "dry run changed rendered/dev"

run --apply >/dev/null || fail "--apply failed"
[ "$(files rendered/dev)" = "README.md,addons/.keep,addons/cert-manager/a.yaml,apps/.keep,apps/podinfo/x.yaml" ] ||
  fail "rendered/dev after prune: $(files rendered/dev)"
[ "$(tip rendered/dev^)" = "$dev0" ] || fail "prune must be one fast-forward commit"
msg=$(git --git-dir="$remote" log -1 --format=%s rendered/dev)
grep -q '^prune(dev): remove external-secrets kgateway (disabled on main ' <<<"$msg" || fail "commit message: $msg"
[ "$(tip rendered/prod)" = "$prod0" ] || fail "nothing stale on rendered/prod, yet it changed"

# idempotent: a second run finds nothing
dev1=$(tip rendered/dev)
out=$(run --apply) || fail "second run failed"
[ "$(tip rendered/dev)" = "$dev1" ] || fail "second run committed again"
grep -q '^rendered/dev: nothing to prune$' <<<"$out" || fail "second run output: $out"

# a rejected push (e.g. Kargo pushed in between) is retried from a fresh fetch
seed rendered/test addons/.keep addons/cert-manager/a.yaml addons/kgateway/b.yaml
printf '#!/bin/sh\n[ -f "$GIT_DIR/rejected" ] && exit 0\ntouch "$GIT_DIR/rejected"; exit 1\n' > "$remote/hooks/pre-receive"
chmod +x "$remote/hooks/pre-receive"
err=$(run --apply 2>&1 >/dev/null) || fail "--apply with one rejected push failed: $err"
grep -q '^rendered/test: push rejected' <<<"$err" || fail "no retry: $err"
[ "$(files rendered/test)" = "addons/.keep,addons/cert-manager/a.yaml" ] || fail "rendered/test: $(files rendered/test)"
rm "$remote/hooks/pre-receive"

# the last addon goes: addons/ keeps its .keep, so the folder Argo/Kargo expect still exists
seed main $cfg/cert-manager/addon.yaml.disabled
run --apply >/dev/null || fail "--apply (all disabled) failed"
[ "$(files rendered/prod)" = "README.md,addons/.keep,apps/.keep" ] || fail "rendered/prod: $(files rendered/prod)"

# unknown argument / unreachable remote fail loudly
assert_fails run --aply
assert_fails env GIT_DIR="$tmp/scratch.git" REMOTE="$tmp/nope.git" "$prune"
