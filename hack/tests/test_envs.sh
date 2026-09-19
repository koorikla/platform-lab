#!/usr/bin/env bash
# Environments are dev, nit, sit, prod (#81), each with N clusters. The one list is kargo-pipeline `stages`: every
# per-env thing elsewhere (fleet files, env values, rendered/* branches) must name an env or stage from it.
# hack/lint.sh fails a fleet file whose env is not a stage env (or not its folder name).
source "$(dirname "$0")/lib.sh"
kv=$charts/kargo-pipeline/values.yaml
assert_yq "$kv" '.stages | map(.name) | join(",")' 'dev-canary,dev,nit,sit,prod'
assert_yq "$kv" '.stages | map(.env) | unique | join(",")' 'dev,nit,sit,prod'
# nit, sit and prod are promoted by hand; prod keeps its pr switch (#6)
assert_yq "$kv" '.autoPromote | join(",")' 'dev-canary,dev'
assert_yq "$kv" '.stages[] | select(.name=="prod") | has("pr")' true
envs=" $(yq '.stages[].env' "$kv" | sort -u | paste -sd' ' -) "

# fleet files: env == folder and a stage env is hack/lint.sh's rule. Every env has an example cluster file (enabled or
# not), so adding a cluster is a copy + rename.
for e in $envs; do
  compgen -G "$config/fleet/clusters/$e/*.yaml*" >/dev/null || fail "no fleet/clusters/$e/ cluster file"
done

# per-env values: addons/workers/<addon>/envs/<env>.values.yaml, repos/apps/<app>/envs/<env>/values.yaml
for f in $config/addons/workers/*/envs/*.values.yaml; do
  [ -e "$f" ] || continue
  e=$(basename "$f" .values.yaml); [[ $envs == *" $e "* ]] || fail "$f: $e is not a stage env"
done
for d in repos/apps/*/envs/*/; do
  e=$(basename "$d"); [[ $envs == *" $e "* ]] || fail "$d: $e is not a stage env"
done

# hack/init-rendered-branches.sh creates rendered/<stage> for every stage (Argo references a branch before Kargo's
# first promotion writes it), and nothing else. Against a throw-away bare remote.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
remote=$tmp/remote.git; git init -q --bare "$remote"; git init -q --bare "$tmp/scratch.git"
GIT_DIR=$tmp/scratch.git REMOTE=$remote hack/init-rendered-branches.sh >/dev/null || fail "init-rendered-branches.sh"
got=$(git --git-dir="$remote" for-each-ref --format='%(refname:strip=3)' refs/heads/rendered/ | sort | paste -sd, -)
want=$(yq '.stages[].name' "$kv" | sort | paste -sd, -)
[ "$got" = "$want" ] || fail "init-rendered-branches.sh created '$got', want '$want'"
t=$(git --git-dir="$remote" ls-tree -r --name-only rendered/nit | paste -sd, -)
[ "$t" = README.md,addons/.keep,apps/.keep ] || fail "rendered/nit holds $t"
# idempotent: an existing branch (Kargo's) is never touched
tip=$(git --git-dir="$remote" rev-parse rendered/sit)
GIT_DIR=$tmp/scratch.git REMOTE=$remote hack/init-rendered-branches.sh >/dev/null || fail "second run"
[ "$(git --git-dir="$remote" rev-parse rendered/sit)" = "$tip" ] || fail "second run moved rendered/sit"
