#!/usr/bin/env bash
# charts.yaml: package + push every chart in repos/platform-charts/ whose version the registry doesn't have yet.
# Published versions are never overwritten (consumers pin them); check-chart-versions.sh makes PRs bump instead.
# DRY_RUN=1 (ci.yaml on PRs, or locally): build deps and package, report what would be pushed, push nothing; registry
# errors other than "not found" (e.g. a still-private package seen anonymously) are warnings then.
# usage: hack/publish-charts.sh oci://ghcr.io/<owner>/platform-charts
set -euo pipefail
reg=${1:?usage: $0 oci://<registry>/<path>}
cd "$(dirname "$0")/.."
charts=repos/platform-charts
out=$(mktemp -d); trap 'rm -rf "$out"' EXIT

# as in lint.sh: helm only resolves https (non-OCI) dependency repos that are registered locally
grep -ho 'repository: https://[^ ]*' "$charts"/*/Chart.yaml | sort -u | awk '{print $2}' |
  while read -r url; do helm repo add "$(echo "$url" | md5 -q 2>/dev/null || echo "$url" | md5sum | cut -c1-32)" "$url" --force-update >/dev/null; done

for c in "$charts"/*/; do
  name=$(yq '.name' "$c/Chart.yaml"); version=$(yq '.version' "$c/Chart.yaml")
  if err=$(helm show chart "$reg/$name" --version "$version" 2>&1 >/dev/null); then
    echo "skip $name:$version (already in $reg)"; continue
  fi
  if ! grep -q 'not found' <<<"$err"; then
    [ -n "${DRY_RUN:-}" ] || { echo "FAIL: $reg/$name:$version: $err" >&2; exit 1; }
    echo "WARN: $reg/$name:$version: $err" >&2
  fi
  ! grep -q '^dependencies:' "$c/Chart.yaml" || helm dependency build "$c" >/dev/null
  helm package "$c" -d "$out" >/dev/null
  if [ -n "${DRY_RUN:-}" ]; then echo "would push $name:$version"; continue; fi
  helm push "$out/$name-$version.tgz" "$reg"
done
