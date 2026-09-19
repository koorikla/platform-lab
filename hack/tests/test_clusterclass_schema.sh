#!/usr/bin/env bash
# ClusterClass files (enabled and disabled) and every fleet file's rendered Cluster, validated against the CRDs of the
# provider versions capi-providers pins (openAPIV3Schema of served versions; CEL rules, webhooks and ClusterClass
# patch semantics are not checked). Also: every jsonPatch path exists in the target template's schema, and a patch
# fed straight from a variable has the type the schema expects there.
# CRDs come from the providers' release assets, cached under ~/.cache/platform-lab; skipped when kubeconform is missing
# or GitHub can't be reached, unless REQUIRE_SCHEMA=1 turns the skip into a failure. REQUIRE_SCHEMA defaults to 1
# under CI (GitHub Actions sets CI=true), so a network blip can't pass there as a SKIP; locally it skips.
source "$(dirname "$0")/lib.sh"
shopt -s nullglob
REQUIRE_SCHEMA=${REQUIRE_SCHEMA:-${CI:+1}}
skip() { [ "${REQUIRE_SCHEMA:-0}" = 1 ] && fail "$1 (REQUIRE_SCHEMA=1)"; echo "SKIP: $1"; exit 0; }
command -v kubeconform >/dev/null || skip "kubeconform not on PATH"
v=$charts/capi-providers/values.yaml
gh=https://github.com
capi=$gh/kubernetes-sigs/cluster-api/releases/download
k3s=$gh/k3s-io/cluster-api-k3s/releases/download
sources="
core $capi/$(yq .core.version $v)/core-components.yaml
capd $capi/$(yq .infrastructure.docker.version $v)/infrastructure-components-development.yaml
k3s-bootstrap $k3s/$(yq .k3s.version $v)/bootstrap-components.yaml
k3s-control-plane $k3s/$(yq .k3s.version $v)/control-plane-components.yaml
capo $gh/kubernetes-sigs/cluster-api-provider-openstack/releases/download/$(yq .infrastructure.openstack.version $v)/infrastructure-components.yaml
capa $gh/kubernetes-sigs/cluster-api-provider-aws/releases/download/$(yq .infrastructure.aws.version $v)/infrastructure-components.yaml
"
cache=${XDG_CACHE_HOME:-$HOME/.cache}/platform-lab/capi-crds
mkdir -p "$cache"
schemas=$tmp/schemas; mkdir -p "$schemas"
while read -r name url; do
  [ -n "$name" ] || continue
  ver=$(basename "$(dirname "$url")")
  crds=$cache/$name-$ver.yaml
  if [ ! -s "$crds" ]; then
    curl -fsSL --max-time 60 "$url" -o "$tmp/$name.yaml" 2>/dev/null || skip "can't download $url (offline?)"
    # CRDs only; write-then-rename so a concurrent run never sees half a file
    yq 'select(.kind == "CustomResourceDefinition")' "$tmp/$name.yaml" > "$crds.$$" && mv "$crds.$$" "$crds"
  fi
  # CRD -> <kind>_<version>.json per served version (yq -s splits by x-name). Objects with declared properties get
  # additionalProperties:false (what the apiserver would silently prune becomes an error), except where the CRD
  # preserves unknown fields.
  (cd "$schemas" && yq -o json -s '.["x-name"]' '.spec.names.kind as $k | .spec.versions[] | select(.served)
    | .schema.openAPIV3Schema * {"x-name": (($k | downcase) + "_" + .name)}
    | (.. | select(tag == "!!map" and has("properties"))
          | select(has("additionalProperties") == false and has("x-kubernetes-preserve-unknown-fields") == false))
      |= . + {"additionalProperties": false}' "$crds") || fail "schemas from $crds"
done <<<"$sources"

validate() {   # validate <what> <multi-doc yaml file>: every document valid, none skipped for a missing schema
  local n; n=$(yq eval-all '[select(.kind != null)] | length' "$2"); [ "$n" -gt 0 ] || fail "$1: nothing to validate"
  kubeconform -strict -summary -schema-location "$schemas/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" - <"$2" >"$tmp/kc.out" 2>&1 ||
    fail "$1: $(cat "$tmp/kc.out")"
  grep -q "Valid: $n, Invalid: 0, Errors: 0, Skipped: 0" "$tmp/kc.out" || fail "$1: $(cat "$tmp/kc.out")"
}

base=$config/fleet/base
for f in $base/clusterclasses/*.yaml $base/clusterclasses/*.yaml.disabled; do
  validate "$f" "$f"
  # jsonPatches: path must exist in the selected template's schema; valueFrom.variable must match its type there
  cc='select(.kind=="ClusterClass")'
  ndef=$(yq eval-all "[$cc | .spec.patches // [] | .[].definitions[]] | length" "$f")
  for ((d = 0; d < ndef; d++)); do
    def="[$cc | .spec.patches[].definitions[]] | .[$d]"
    kind=$(yq eval-all "$def | .selector.kind" "$f" | tr '[:upper:]' '[:lower:]')
    ver=$(yq eval-all "$def | .selector.apiVersion" "$f"); ver=${ver##*/}
    s=$schemas/${kind}_$ver.json; [ -f "$s" ] || fail "$f: no schema for patch target $kind $ver"
    nop=$(yq eval-all "$def | .jsonPatches | length" "$f")
    for ((p = 0; p < nop; p++)); do
      op=$(yq eval-all "$def | .jsonPatches[$p].op" "$f"); path=$(yq eval-all "$def | .jsonPatches[$p].path" "$f")
      # /a/b/0/c -> .properties.a.properties.b.items.properties.c
      q=$(awk -F/ '{ for (i = 2; i <= NF; i++) printf ($i ~ /^([0-9]+|-)$/ ? ".items" : ".properties[\"%s\"]"), $i }' <<<"$path")
      [ "$(yq -p json -o yaml "$q | type" "$s")" = '!!map' ] || fail "$f: $op $path: no such field in $kind $ver"
      var=$(yq eval-all "$def | .jsonPatches[$p].valueFrom.variable // \"\"" "$f")
      # only whole variables; builtin.* and nested paths (a.b) are not resolved here
      [ -n "$var" ] && [ "$op" != remove ] && [ "$var" = "${var%%.*}" ] || continue
      want=$(yq -p json -o yaml "$q.type // \"\"" "$s")
      got=$(yq -N "$cc | .spec.variables[] | select(.name == \"$var\") | .schema.openAPIV3Schema.type" "$f")
      [ -z "$want" ] || [ "$want" = "$got" ] || fail "$f: $path wants $want, variable $var is $got"
    done
  done
done

for ff in $config/fleet/clusters/*/*.yaml $config/fleet/clusters/*/*.yaml.disabled; do
  o=$(render "$(yq '.name' "$ff")" $charts/cluster -f "$ff")
  yq 'select(.kind == "Cluster")' "$o" > "$tmp/cluster.yaml"
  validate "$ff" "$tmp/cluster.yaml"
done
