#!/usr/bin/env bash
# openchoreo-app renders validated against the real OpenChoreo CRDs (openAPIV3Schema; CEL rules and webhooks are not
# checked). CRDs come from the openchoreo-control-plane chart at the version the umbrella pins, cached under
# ~/.cache/platform-lab; skipped when kubeconform is missing or the chart can't be pulled (offline). By hand:
#   helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane --version <v> --untar
#   convert crds/*.yaml -> <kind>_<version>.json (as below), then
#   helm template ... | kubeconform -strict -summary -schema-location '<dir>/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
source "$(dirname "$0")/lib.sh"
command -v kubeconform >/dev/null || { echo "SKIP: kubeconform not on PATH"; exit 0; }
ver=$(yq '.dependencies[] | select(.name=="openchoreo-control-plane") | .version' $charts/openchoreo-control-plane/Chart.yaml)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab/openchoreo-control-plane-$ver
if [ ! -d "$cache/crds" ]; then
  helm pull oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane --version "$ver" --untar --untardir "$tmp" \
    >/dev/null 2>&1 || { echo "SKIP: can't pull openchoreo-control-plane $ver (offline?)"; exit 0; }
  mkdir -p "$cache" && cp -R "$tmp/openchoreo-control-plane/crds" "$cache/crds.$$" && mv "$cache/crds.$$" "$cache/crds"
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
a=hack/tests/fixtures/podinfo
kc() { kubeconform -strict -summary -schema-location "$schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" - <"$1"; }
validate() {   # validate <what> <render file>; stdin: kubeconform skips files without a .yaml extension
  local n; n=$(yq eval-all '[select(.kind != null)] | length' "$2"); [ "$n" -gt 0 ] || fail "$1: empty render"
  kc "$2" >"$tmp/kc.out" 2>&1 || fail "$1: $(cat "$tmp/kc.out")"
  grep -q "Valid: $n, Invalid: 0, Errors: 0, Skipped: 0" "$tmp/kc.out" || fail "$1: $(cat "$tmp/kc.out")"
}
o=$(render types $c --set mode=types);                                               validate types "$o"
o=$(render podinfo $c -f $a/app.yaml --set mode=component --set createProject=true); validate component "$o"
o=$(render podinfo $c -f $a/app.yaml -f $a/envs/dev/values.yaml --set env=dev --set mode=release --set image.tag=6.15.0 \
      --set parameters.foo=bar);                                                     validate release "$o"
o=$(render podinfo $c -f $a/app.yaml -f $a/envs/dev/values.yaml --set env=dev --set mode=binding --set image.tag=6.15.0 \
      --set environment=dev1 --set 'workloadOverrides.container.env[0].key=A' --set 'workloadOverrides.container.env[0].value=b')
validate binding "$o"
# the check has teeth: an unknown field fails
o=$(render podinfo $c -f $a/app.yaml --set mode=component)
yq -i '.spec.bogus = 1' "$o"
if kc "$o" >/dev/null 2>&1; then
  fail "kubeconform accepted an unknown field"
fi
