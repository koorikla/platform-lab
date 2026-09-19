#!/usr/bin/env bash
# charts.yaml: package + push every chart in repos/platform-charts/ whose version the registry doesn't have yet.
# Published versions are never overwritten (consumers pin them); check-chart-versions.sh makes PRs bump instead.
# DRY_RUN=1 (ci.yaml on PRs, or locally): build deps and package, report what would be pushed, push nothing; one
# existence check per chart and unexpected registry errors are only warnings.
# usage: hack/publish-charts.sh oci://ghcr.io/<owner>/platform-charts
set -euo pipefail
reg=${1:?usage: $0 oci://<registry>/<path>}
cd "$(dirname "$0")/.."
charts=repos/platform-charts
tries=3; [ -z "${DRY_RUN:-}" ] || tries=1
pause=${SHOW_PAUSE:-5}
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

# as in lint.sh: helm only resolves https (non-OCI) dependency repos that are registered locally
grep -ho 'repository: https://[^ ]*' "$charts"/*/Chart.yaml | sort -u | awk '{print $2}' |
  while read -r url; do helm repo add "$(echo "$url" | md5 -q 2>/dev/null || echo "$url" | md5sum | cut -c1-32)" "$url" --force-update >/dev/null; done

for c in "$charts"/*/; do
  name=$(yq '.name' "$c/Chart.yaml"); version=$(yq '.version' "$c/Chart.yaml")
  # only a successful read skips; "not found" is definite, anything else is retried (a transient 401/403 from GHCR's
  # token exchange must not turn into a push that overwrites the tag)
  published=""
  for ((i = 1; i <= tries; i++)); do
    if err=$(helm show chart "$reg/$name" --version "$version" 2>&1 >/dev/null); then published=1; break; fi
    if grep -q ': not found' <<<"$err"; then break; fi
    if ((i < tries)); then sleep "$pause"; fi
  done
  if [ -n "$published" ]; then echo "skip $name:$version (already in $reg)"; continue; fi
  # GHCR answers "403: denied" instead of "not found" for a package the caller can't see, incl. one that doesn't exist
  # yet (seen anonymously from Actions runners). Pushing then is still safe: whoever may write a package may read it,
  # so a persistent denied read means no such version, or a push that fails too. Other errors (5xx, network) stop.
  # The registry's answer is always logged: check a publish log for which answer GITHUB_TOKEN actually gets.
  if ! grep -qE ': (not found|denied|unauthorized)' <<<"$err"; then
    [ -n "${DRY_RUN:-}" ] || { echo "FAIL: $reg/$name:$version: $err" >&2; exit 1; }
    echo "WARN: $reg/$name:$version: $err" >&2
  fi
  ! grep -q '^dependencies:' "$c/Chart.yaml" || helm dependency build "$c" >/dev/null
  helm package "$c" -d "$out" >/dev/null
  if [ -n "${DRY_RUN:-}" ]; then echo "would push $name:$version (registry said: $err)"; continue; fi
  echo "push $name:$version (registry said: $err)"
  helm push "$out/$name-$version.tgz" "$reg"
done
