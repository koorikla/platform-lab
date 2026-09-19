#!/usr/bin/env bash
# Provider extension points (#23): one ClusterClass per file, fleet/base/clusterclasses/<class>.yaml (disabled examples
# as .yaml.disabled), synced by fleet-base (directory.recurse); bootstrap.sh applies the lab's class by path.
# Only what CAPI's own validation wouldn't tell us before a cluster exists: every template ref resolves to a document
# of the file (and every document is used), patches read only declared variables (and every variable is used), no
# Secrets in class files, an enabled cluster never names a disabled class, the provider label matches the class, and
# the cloud provider pins respect their Renovate caps (the CAPI 1.12 line). Field/type checks against the provider
# CRDs: test_clusterclass_schema.sh.
source "$(dirname "$0")/lib.sh"
shopt -s nullglob
base=$config/fleet/base
cc='select(.kind=="ClusterClass")'
# lines of $1 that are not in $2 (both newline lists, blank lines ignored)
missing_from() { comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u); }
y() { yq -N "$@"; }   # per document: string concatenation stays within one object

# fleet-base must recurse, or nothing under fleet/base/clusterclasses/ would ever sync
assert_yq $config/argocd/apps.yaml 'select(.metadata.name=="fleet-base") | .spec.source.directory.recurse' true

class_file() {   # class_file <class> -> its file, enabled first; nothing if there is none
  local f
  for f in "$base/clusterclasses/$1.yaml" "$base/clusterclasses/$1.yaml.disabled"; do
    [ -f "$f" ] && { echo "$f"; return; }
  done
  return 0
}

# every ClusterClass lives in clusterclasses/ (a class elsewhere in fleet/base would escape the checks below)
stray=$(grep -rlE --include='*.yaml' --include='*.yaml.disabled' '^kind: ClusterClass\b' "$base" | grep -v "^$base/clusterclasses/" || true)
[ -z "$stray" ] || fail "ClusterClass outside $base/clusterclasses/: $stray"
# bootstrap.sh applies the lab's class (and other config files) to the k3d cluster by path
for p in $(grep -oE '\$config/[A-Za-z0-9_./-]+\.yaml' bootstrap/bootstrap.sh); do
  [ -f "$config/${p#\$config/}" ] || fail "bootstrap/bootstrap.sh applies $p, which doesn't exist"
done

files=("$base"/clusterclasses/*.yaml "$base"/clusterclasses/*.yaml.disabled)
[ ${#files[@]} -ge 3 ] || fail "expected k3s-docker, k3s-openstack and eks ClusterClass files, got: ${files[*]}"
for f in "${files[@]}"; do
  n=$(basename "$f"); n=${n%.disabled}; n=${n%.yaml}
  [ "$(y "$cc | .metadata.name" "$f")" = "$n" ] || fail "$f: one ClusterClass, named after the file ($n)"
  [ "$(yq eval-all '[select(.kind == "Secret")] | length' "$f")" = 0 ] || fail "$f: no Secrets in git (credentials: OpenBao/ESO)"

  refs=$(y "$cc | .spec | [.controlPlane.ref, .controlPlane.machineInfrastructure.ref, .infrastructure.ref,
      (.workers.machineDeployments // [] | .[] | (.template.bootstrap.ref, .template.infrastructure.ref))] | .[]
      | select(. != null) | .apiVersion + \"/\" + .kind + \"/\" + .name" "$f")
  docs=$(y 'select(.kind != null and .kind != "ClusterClass") | .apiVersion + "/" + .kind + "/" + .metadata.name' "$f")
  [ -z "$(missing_from "$refs" "$docs")" ] || fail "$f: refs without a document: $(missing_from "$refs" "$docs")"
  [ -z "$(missing_from "$docs" "$refs")" ] || fail "$f: documents no ref uses: $(missing_from "$docs" "$refs")"

  declared=$(y "$cc | .spec.variables // [] | .[].name" "$f")
  # valueFrom.variable, plus the first path segment of every .var inside {{ }} (enabledIf, valueFrom.template)
  used=$( { y "$cc | .spec.patches // [] | .. | select(tag == \"!!map\" and has(\"variable\")) | .variable" "$f"
            y "$cc | .spec.patches // []" "$f" | grep -oE '\{\{[^}]*\}\}' | grep -oE '(^|[^A-Za-z0-9_.])\.[A-Za-z][A-Za-z0-9]*' |
              sed 's/^[^.]*\.//'; } | sed 's/\..*//' | grep -vx builtin || true)
  [ -z "$(missing_from "$used" "$declared")" ] || fail "$f: patches read undeclared variables: $(missing_from "$used" "$declared")"
  [ -z "$(missing_from "$declared" "$used")" ] || fail "$f: variables no patch uses: $(missing_from "$declared" "$used")"
done
# invariant 1 on EKS: the EKS cluster is named after the CAPI Cluster, not something CAPA derives
assert_yq $base/clusterclasses/eks.yaml.disabled \
  "$cc | .spec.patches[].definitions[].jsonPatches[] | select(.path == \"/spec/template/spec/eksClusterName\") | .valueFrom.template" \
  '{{ .builtin.cluster.name }}'

for ff in $config/fleet/clusters/*/*.yaml $config/fleet/clusters/*/*.yaml.disabled; do
  class=$(yq '.clusterClass // "k3s-docker"' "$ff")
  cf=$(class_file "$class"); [ -n "$cf" ] || fail "$ff: no ClusterClass file for '$class'"
  if [[ $ff == *.yaml && $cf == *.disabled ]]; then fail "$ff is enabled but its ClusterClass is disabled ($cf)"; fi
  infra=$(y "$cc | .spec.infrastructure.ref.kind" "$cf")
  case $infra in
    Docker*) p=docker ;;
    OpenStack*) p=openstack ;;
    AWS*) p=aws ;;
    *) fail "$cf: infrastructure kind $infra: add its platform.lab/provider value here" ;;
  esac
  [ "$(yq '.provider' "$ff")" = "$p" ] || fail "$ff: provider must be '$p' for class $class"
done

# capi-providers: cloud providers are opt-in (chart unit tests: repos/platform-charts/capi-providers/tests/)
c=$charts/capi-providers
# pins stay under their Renovate cap (the last line built on our CAPI core minor; reasons in renovate.json/values.yaml)
for p in openstack:cluster-api-provider-openstack aws:cluster-api-provider-aws; do
  ver=$(yq ".infrastructure.${p%%:*}.version" $c/values.yaml); ver=${ver#v}
  cap=$(yq -p json -o yaml ".packageRules[] | select(.matchDepNames // [] | contains([\"${p#*:}\"])) | .allowedVersions // \"\"" renovate.json | sed '/^$/d')
  [[ $cap == '<'* ]] || fail "renovate: ${p#*:} needs an allowedVersions '<x.y.z' cap, got '$cap'"
  [ "$(printf '%s\n%s\n' "$ver" "${cap#<}" | sort -V | head -1)" = "$ver" ] && [ "$ver" != "${cap#<}" ] ||
    fail "${p%%:*} v$ver is not below its Renovate cap $cap"
done
