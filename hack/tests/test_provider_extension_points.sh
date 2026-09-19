#!/usr/bin/env bash
# Provider extension points (#23): one ClusterClass per file, fleet/base/clusterclasses/<class>.yaml (disabled examples
# as .yaml.disabled; the legacy fleet/base/clusterclass-<class>.yaml until it moves there), synced by fleet-base.
# Per class file: one ClusterClass named after the file, everything in namespace fleet, no Secrets (credentials come
# from OpenBao/ESO), every template ref resolves to a document of the file and every document is referenced, patches
# select referenced templates and existing worker classes, and read only declared variables (all of which are used).
# Per fleet file, enabled or not: the rendered Cluster names an existing class (an enabled cluster needs an enabled
# class), sets only declared variables and every required one without a default, uses a declared worker class, sets
# controlPlane.replicas exactly when the class has machines for its control plane (EKS: managed, no replicas), and its
# platform.lab/provider label matches the class's infrastructure provider. Schema checks: test_clusterclass_schema.sh.
source "$(dirname "$0")/lib.sh"
shopt -s nullglob
base=$config/fleet/base
cc='select(.kind=="ClusterClass")'
cl='select(.kind=="Cluster")'
# lines of $1 that are not in $2 (both newline lists, blank lines ignored)
missing_from() { comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u); }
y() { yq -N "$@"; }            # per document: string concatenation stays within one object
ya() { yq eval-all "$@"; }       # across documents: counts

# fleet-base must recurse, or nothing under fleet/base/clusterclasses/ would ever sync
assert_yq $config/argocd/apps.yaml 'select(.metadata.name=="fleet-base") | .spec.source.directory.recurse' true

# the extension points this issue ships (disabled until a provider is enabled on the hub)
for f in $base/clusterclasses/k3s-openstack.yaml.disabled $base/clusterclasses/eks.yaml.disabled \
         $config/fleet/clusters/dev/os-dev1.yaml.disabled $config/fleet/clusters/dev/eks-dev1.yaml.disabled; do
  [ -f "$f" ] || fail "missing $f"
done

class_file() {   # class_file <class> -> its file, enabled first; nothing if there is none
  local f
  for f in "$base/clusterclasses/$1.yaml" "$base/clusterclass-$1.yaml" "$base/clusterclasses/$1.yaml.disabled"; do
    [ -f "$f" ] && { echo "$f"; return; }
  done
  return 0
}

files=($base/clusterclass-*.yaml $base/clusterclasses/*.yaml $base/clusterclasses/*.yaml.disabled)
[ ${#files[@]} -ge 3 ] || fail "expected k3s-docker, k3s-openstack and eks ClusterClass files, got: ${files[*]}"
for f in "${files[@]}"; do
  n=$(basename "$f"); n=${n#clusterclass-}; n=${n%.disabled}; n=${n%.yaml}
  [ "$(ya "[$cc] | length" "$f")" = 1 ] || fail "$f: want exactly one ClusterClass"
  [ "$(y "$cc | .metadata.name" "$f")" = "$n" ] || fail "$f: ClusterClass name must be the file name ($n)"
  [ "$(ya '[select(.kind != null and .metadata.namespace != "fleet")] | length' "$f")" = 0 ] || fail "$f: everything lives in namespace fleet"
  [ "$(ya '[select(.kind == "Secret")] | length' "$f")" = 0 ] || fail "$f: no Secrets in git (credentials: OpenBao/ESO)"

  refs=$(y "$cc | .spec | [.controlPlane.ref, .controlPlane.machineInfrastructure.ref, .infrastructure.ref,
      (.workers.machineDeployments // [] | .[] | (.template.bootstrap.ref, .template.infrastructure.ref))] | .[]
      | select(. != null) | .apiVersion + \"/\" + .kind + \"/\" + .name" "$f")
  docs=$(y 'select(.kind != null and .kind != "ClusterClass") | .apiVersion + "/" + .kind + "/" + .metadata.name' "$f")
  [ -z "$(missing_from "$refs" "$docs")" ] || fail "$f: refs without a document: $(missing_from "$refs" "$docs")"
  [ -z "$(missing_from "$docs" "$refs")" ] || fail "$f: documents no ref uses: $(missing_from "$docs" "$refs")"

  kinds=$(sed 's#/[^/]*$##' <<<"$refs")   # apiVersion/kind
  sel=$(y "$cc | .spec.patches // [] | .[].definitions[].selector | .apiVersion + \"/\" + .kind" "$f")
  [ -z "$(missing_from "$sel" "$kinds")" ] || fail "$f: patch selects a template the class doesn't use: $(missing_from "$sel" "$kinds")"
  wcs=$(y "$cc | .spec.workers.machineDeployments // [] | .[].class" "$f")
  selw=$(y "$cc | .spec.patches // [] | .[].definitions[].selector.matchResources.machineDeploymentClass.names // [] | .[]" "$f")
  [ -z "$(missing_from "$selw" "$wcs")" ] || fail "$f: patch selects unknown worker class: $(missing_from "$selw" "$wcs")"

  declared=$(y "$cc | .spec.variables // [] | .[].name" "$f")
  # valueFrom.variable, plus the first path segment of every .var inside {{ }} (enabledIf, valueFrom.template)
  used=$( { y "$cc | .spec.patches // [] | .. | select(tag == \"!!map\" and has(\"variable\")) | .variable" "$f"
            y "$cc | .spec.patches // []" "$f" | grep -oE '\{\{[^}]*\}\}' | grep -oE '(^|[^A-Za-z0-9_.])\.[A-Za-z][A-Za-z0-9]*' |
              sed 's/^[^.]*\.//'; } | sed 's/\..*//' | grep -vx builtin || true)
  [ -z "$(missing_from "$used" "$declared")" ] || fail "$f: patches read undeclared variables: $(missing_from "$used" "$declared")"
  [ -z "$(missing_from "$declared" "$used")" ] || fail "$f: variables no patch uses: $(missing_from "$declared" "$used")"
done

# every cluster file against its class
for ff in $config/fleet/clusters/*/*.yaml $config/fleet/clusters/*/*.yaml.disabled; do
  o=$(render "$(yq '.name' "$ff")" $charts/cluster -f "$ff")
  class=$(y "$cl | .spec.topology.class" "$o")
  cf=$(class_file "$class"); [ -n "$cf" ] || fail "$ff: no ClusterClass file for '$class'"
  if [[ $ff == *.yaml && $cf == *.disabled ]]; then fail "$ff is enabled but its ClusterClass is disabled ($cf)"; fi

  set=$(y "$cl | .spec.topology.variables // [] | .[].name" "$o")
  declared=$(y "$cc | .spec.variables // [] | .[].name" "$cf")
  required=$(y "$cc | .spec.variables // [] | .[] | select(.required and .schema.openAPIV3Schema.default == null) | .name" "$cf")
  [ -z "$(missing_from "$set" "$declared")" ] || fail "$ff: variables $class doesn't declare: $(missing_from "$set" "$declared")"
  [ -z "$(missing_from "$required" "$set")" ] || fail "$ff: required variables of $class not set: $(missing_from "$required" "$set")"

  wc=$(y "$cl | .spec.topology.workers.machineDeployments[].class" "$o")
  [ -z "$(missing_from "$wc" "$(y "$cc | .spec.workers.machineDeployments[].class" "$cf")")" ] || fail "$ff: worker class '$wc' not in $class"

  machines=$(y "$cc | .spec.controlPlane.machineInfrastructure.ref.kind // \"\"" "$cf")
  replicas=$(y "$cl | .spec.topology.controlPlane.replicas // \"\"" "$o")
  if [ -n "$machines" ] && [ -z "$replicas" ]; then fail "$ff: $class has control-plane machines: set controlPlaneReplicas"; fi
  if [ -z "$machines" ] && [ -n "$replicas" ]; then fail "$ff: $class has a managed control plane: controlPlaneReplicas: null"; fi

  infra=$(y "$cc | .spec.infrastructure.ref.kind" "$cf")
  case $infra in
    Docker*) p=docker ;;
    OpenStack*) p=openstack ;;
    AWS*) p=aws ;;
    *) fail "$cf: infrastructure kind $infra: add its provider label value to this test" ;;
  esac
  [ "$(y "$cl | .metadata.labels[\"platform.lab/provider\"]" "$o")" = "$p" ] || fail "$ff: provider must be '$p' for $class"
  [ -n "$(y "$cl | .metadata.labels[\"platform.lab/region\"] // \"\"" "$o")" ] || fail "$ff: region label is empty"
done

# EKS: the EKS cluster is named after the CAPI Cluster (invariant 1), not a name CAPA derives from namespace + control plane
eks=$base/clusterclasses/eks.yaml.disabled
assert_yq "$eks" "$cc | .spec.patches[].definitions[].jsonPatches[] | select(.path == \"/spec/template/spec/eksClusterName\") | .valueFrom.template" '{{ .builtin.cluster.name }}'
o=$(render eks-dev1 $charts/cluster -f $config/fleet/clusters/dev/eks-dev1.yaml.disabled)
assert_yq "$o" "$cl | .spec.topology.version" v1.34.0
o=$(render os-dev1 $charts/cluster -f $config/fleet/clusters/dev/os-dev1.yaml.disabled)
assert_yq "$o" "$cl | .spec.topology.controlPlane.replicas" 1

# capi-providers: cloud providers are opt-in toggles and stay on the CAPI core line we pin
c=$charts/capi-providers
o=$(render capi-providers $c)
assert_yq "$o" '[select(.kind=="InfrastructureProvider") | .metadata.name] | join(",")' docker
o=$(render capi-providers $c --set infrastructure.openstack.enabled=true --set infrastructure.aws.enabled=true)
ip='select(.kind=="InfrastructureProvider" and .metadata.name=='
assert_yq "$o" "$ip\"openstack\") | .metadata.namespace + \"/\" + .spec.version" "capo-system/$(yq '.infrastructure.openstack.version' $c/values.yaml)"
assert_yq "$o" "$ip\"aws\") | .metadata.namespace + \"/\" + .spec.version" "capa-system/$(yq '.infrastructure.aws.version' $c/values.yaml)"
# CAPA's components need AWS_B64ENCODED_CREDENTIALS (no default): the operator reads it from configSecret
assert_yq "$o" "$ip\"aws\") | .spec.configSecret.name + \"/\" + .spec.configSecret.namespace" capa-variables/capa-system
core=$(yq '.core.version' $c/values.yaml | cut -d. -f1,2)
case $core in   # provider line built on this CAPI minor (sigs.k8s.io/cluster-api in the provider's go.mod)
  v1.12) capo=v0.14 capa=v2.12 ;;   # CAPO v0.15 = v1beta2 contract on CAPI 1.14; CAPA v2.13 = CAPI 1.13
  *) fail "CAPI core moved to $core: re-check CAPO/CAPA go.mod and metadata.yaml, then update this table" ;;
esac
[ "$(yq '.infrastructure.openstack.version' $c/values.yaml | cut -d. -f1,2)" = $capo ] || fail "CAPO must stay on $capo.x with core $core"
[ "$(yq '.infrastructure.aws.version' $c/values.yaml | cut -d. -f1,2)" = $capa ] || fail "CAPA must stay on $capa.x with core $core"
# Renovate keeps both pins current, capped at the same line
for dep in cluster-api-provider-openstack cluster-api-provider-aws; do
  [ "$(yq -p json -o yaml "[.customManagers[] | select(.depNameTemplate == \"$dep\")] | length" renovate.json)" = 1 ] || fail "renovate: no manager for $dep"
  [ "$(yq -p json -o yaml "[.packageRules[] | select(.matchDepNames // [] | contains([\"$dep\"])) | .allowedVersions // \"\"] | map(select(. != \"\")) | length" renovate.json)" = 1 ] ||
    fail "renovate: $dep needs an allowedVersions cap"
done
