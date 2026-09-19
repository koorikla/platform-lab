#!/usr/bin/env bash
# helm-unittest suites next to each chart (repos/platform-charts/<chart>/tests/*_test.yaml): chart behaviour with
# chart-local values only, so the tests travel with the chart when repos/* split (CLAUDE.md invariant 6).
# usage: hack/tests/unittest.sh [chart dir...]   (default: every chart that has a tests/ dir)
# The pinned plugin is installed on first use into its own HELM_PLUGINS under ~/.cache/platform-lab: another unittest
# version installed for other work is neither used nor replaced.
source "$(dirname "$0")/lib.sh"
# renovate: datasource=github-releases depName=helm-unittest/helm-unittest
HELM_UNITTEST_VERSION=v1.1.2
plugins=${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab/helm-plugins/unittest-$HELM_UNITTEST_VERSION
export HELM_PLUGINS=$plugins
installed() { helm plugin list 2>/dev/null | awk '$1 == "unittest" {print "v" $2}'; }
if [ "$(installed)" != "$HELM_UNITTEST_VERSION" ]; then
  # one installer at a time (mkdir is atomic); a run that waited finds the plugin installed and skips. A lock older than
  # 10 min is an interrupted install: taken over.
  mkdir -p "$(dirname "$plugins")"; lock=$plugins.lock
  for _ in $(seq 600); do
    mkdir "$lock" 2>/dev/null && break
    [ -z "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ] || { rm -rf "$lock"; continue; }
    sleep 1
  done
  [ -d "$lock" ] || fail "could not take $lock"
  trap 'rm -rf "$lock" "$tmp"' EXIT   # lib.sh's cleanup of $tmp, plus the lock
fi
if [ "$(installed)" != "$HELM_UNITTEST_VERSION" ]; then
  # under the lock: a leftover dir is a broken install (wrong version or interrupted), and a stale temp copy is garbage
  rm -rf "$plugins" "$plugins".??????
  new=$(mktemp -d "$plugins.XXXXXX")
  # helm 4 verifies plugin sources by default and can't verify a git source (the plugin README says --verify=false);
  # helm 3 has no --verify flag. Either way the tag is pinned and the plugin's install hook checks the downloaded
  # release binary against the release's checksum file.
  v=(); [[ $(helm version --short) == v3.* ]] || v=(--verify=false)
  echo "installing helm-unittest $HELM_UNITTEST_VERSION into $plugins" >&2
  HELM_PLUGINS=$new helm plugin install https://github.com/helm-unittest/helm-unittest.git \
    --version "$HELM_UNITTEST_VERSION" "${v[@]}" >"$tmp/install.log" 2>&1 ||
    { cat "$tmp/install.log" >&2; rm -rf "$new"; fail "helm plugin install helm-unittest $HELM_UNITTEST_VERSION"; }
  # rename into place: a run that doesn't wait for the lock sees either no plugin dir or a complete one
  mv "$new" "$plugins"
  [ "$(installed)" = "$HELM_UNITTEST_VERSION" ] || fail "helm-unittest $HELM_UNITTEST_VERSION not installed in $plugins"
fi
[ -z "${lock:-}" ] || { rm -rf "$lock"; trap 'rm -rf "$tmp"' EXIT; }

if [ $# -eq 0 ]; then
  set --
  for d in "$charts"/*/tests; do [ -d "$d" ] && set -- "$@" "${d%/tests}"; done
fi
rc=0
for c in "$@"; do
  deps "$c"
  # --strict: unknown keys in a suite are errors, not silently ignored assertions
  if out=$(helm unittest --strict "$c" 2>&1); then
    echo "ok   unittest $(basename "$c") ($(grep -E '^Tests:' <<<"$out" | tr -s ' '))"
  else
    echo "$out"; echo "FAIL unittest $(basename "$c")"; rc=1
  fi
done
exit $rc
