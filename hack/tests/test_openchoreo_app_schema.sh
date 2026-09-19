#!/usr/bin/env bash
# openchoreo-app renders validated against the real OpenChoreo CRDs (openAPIV3Schema; CEL rules and webhooks are not
# checked). CRDs come from the openchoreo-control-plane chart at the version the umbrella pins, cached under
# ~/.cache/platform-lab; skipped when kubeconform is missing or the chart can't be pulled (offline), unless
# REQUIRE_SCHEMA=1 (CI) turns the skip into a failure. By hand:
#   helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane --version <v> --untar
#   convert crds/*.yaml -> <kind>_<version>.json (as below), then
#   helm template ... | kubeconform -strict -summary -schema-location '<dir>/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
source "$(dirname "$0")/lib.sh"
skip() { [ "${REQUIRE_SCHEMA:-0}" = 1 ] && fail "$1 (REQUIRE_SCHEMA=1)"; echo "SKIP: $1"; exit 0; }
command -v kubeconform >/dev/null || skip "kubeconform not on PATH"
ver=$(yq '.dependencies[] | select(.name=="openchoreo-control-plane") | .version' $charts/openchoreo-control-plane/Chart.yaml)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab/openchoreo-control-plane-$ver
if [ ! -d "$cache/crds" ]; then
  helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane --version "$ver" --untar --untardir "$tmp" \
    >/dev/null 2>&1 || skip "can't pull openchoreo-control-plane $ver (offline?)"
  # copy then rename: a concurrent run either sees no crds/ or a complete one (loser's copy is dropped)
  mkdir -p "$cache" && cp -R "$tmp/openchoreo-control-plane/crds" "$cache/crds.$$"
  [ -d "$cache/crds" ] || mv "$cache/crds.$$" "$cache/crds"; rm -rf "$cache/crds.$$"
fi

# CRD -> JSON schema per served version. Objects with declared properties get additionalProperties:false (what the
# apiserver's pruning would silently drop becomes an error here), except where the CRD preserves unknown fields.
schemas=$tmp/schemas; mkdir -p "$schemas"
for f in "$cache"/crds/*.yaml; do
  kind=$(yq '.spec.names.kind | downcase' "$f")
  for v in $(yq '.spec.versions[].name' "$f"); do
    yq -o json "(.spec.versions[] | select(.name==\"$v\") | .schema.openAPIV3Schema)
      | (.. | select(tag == \"!!map\" and has(\"properties\"))
            | select(has(\"additionalProperties\") == false and has(\"x-kubernetes-preserve-unknown-fields\") == false))
        |= . + {\"additionalProperties\": false}" "$f" > "$schemas/${kind}_$v.json"
  done
done

c=$charts/openchoreo-app
a=$c/tests/values/podinfo   # the chart's unit-test app (shaped like repos/apps/<app>/)
kc() { kubeconform -strict -summary -schema-location "$schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" - <"$1"; }
validate() {   # validate <what> <render file>; stdin: kubeconform skips files without a .yaml extension
  local n; n=$(yq eval-all '[select(.kind != null)] | length' "$2"); [ "$n" -gt 0 ] || fail "$1: empty render"
  kc "$2" >"$tmp/kc.out" 2>&1 || fail "$1: $(cat "$tmp/kc.out")"
  grep -q "Valid: $n, Invalid: 0, Errors: 0, Skipped: 0" "$tmp/kc.out" || fail "$1: $(cat "$tmp/kc.out")"
}
o=$(render types $c --set mode=types);                                               validate types "$o"
o=$(render podinfo $c -f $a/app.yaml --set mode=component --set createProject=true); validate component "$o"
o=$(render podinfo $c -f $a/app.yaml -f $a/envs/dev/values.yaml --set env=dev --set stage=dev --set mode=release \
      --set image.tag=6.15.0 --set parameters.foo=bar);                             validate release "$o"
o=$(render podinfo $c --set mode=binding --set name=podinfo --set project=lab --set releaseName=podinfo-dev-1-0-0-abcdef12 \
      --set environment=dev1);                                                       validate binding "$o"
# the real apps (repos/apps/<app>/app.yaml + envs/<env>/values.yaml), as render-app and #17's component appset render them
for af in repos/apps/*/app.yaml; do
  d=$(dirname "$af"); n=$(basename "$d")
  o=$(render "$n" $c -f "$af" --set mode=component);                                 validate "$n component" "$o"
  for e in "$d"/envs/*/; do
    e=$(basename "$e")
    o=$(render "$n" $c -f "$af" -f "$d/envs/$e/values.yaml" --set mode=release --set stage="$e" \
          --set-literal image.tag=1.0.0);                                            validate "$n release $e" "$o"
  done
done
# the check has teeth: an unknown field fails
o=$(render podinfo $c -f $a/app.yaml --set mode=component)
yq -i '.spec.bogus = 1' "$o"
if kc "$o" >/dev/null 2>&1; then
  fail "kubeconform accepted an unknown field"
fi
