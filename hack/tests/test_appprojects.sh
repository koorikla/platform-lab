#!/usr/bin/env bash
# Least-privilege AppProjects (#20): everything git makes Argo CD deploy must be admitted by its project, and the
# projects must still reject what they exist to reject. Evaluated by hack/appproject-check.sh (Argo CD v3.5.3 +
# argocd-agent v0.10.0 rules); the same checker runs read-only against the live hub (--live) before a merge.
# Renders here are what Argo/Kargo render: hub addons and pipelines on the hub, worker addons as render-addon does
# (fleet < env values, --include-crds), apps with their env values; one record per resource.
source "$(dirname "$0")/lib.sh"
projects=$config/argocd/projects.yaml
recs=$tmp/records.tsv; : >"$recs"
check() { hack/appproject-check.sh --projects "${2:-$projects}" <"$1"; }

# Kubernetes 1.34 built-in cluster-scoped kinds (kubectl api-resources --namespaced=false); CRD kinds come from the
# rendered CRDs themselves. A rendered object without metadata.namespace is namespaced (lands in the app's namespace)
# unless its kind is listed here.
builtin_cluster='
/ComponentStatus /Namespace /Node /PersistentVolume
admissionregistration.k8s.io/MutatingWebhookConfiguration admissionregistration.k8s.io/ValidatingWebhookConfiguration
admissionregistration.k8s.io/ValidatingAdmissionPolicy admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding
admissionregistration.k8s.io/MutatingAdmissionPolicy admissionregistration.k8s.io/MutatingAdmissionPolicyBinding
apiextensions.k8s.io/CustomResourceDefinition apiregistration.k8s.io/APIService
certificates.k8s.io/CertificateSigningRequest flowcontrol.apiserver.k8s.io/FlowSchema
flowcontrol.apiserver.k8s.io/PriorityLevelConfiguration networking.k8s.io/IPAddress networking.k8s.io/IngressClass
networking.k8s.io/ServiceCIDR node.k8s.io/RuntimeClass rbac.authorization.k8s.io/ClusterRole
rbac.authorization.k8s.io/ClusterRoleBinding resource.k8s.io/DeviceClass resource.k8s.io/ResourceSlice
scheduling.k8s.io/PriorityClass storage.k8s.io/CSIDriver storage.k8s.io/CSINode storage.k8s.io/StorageClass
storage.k8s.io/VolumeAttachment storage.k8s.io/VolumeAttributesClass'

renders=$tmp/renders; mkdir -p "$renders"
# add <app> <project> <cluster> <namespace> <manifest file>: records the app's destination + every rendered resource
add() {
  cp "$5" "$renders/$1.$3.yaml"
  printf 'dst\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$recs"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$tmp/apps.tsv"
}
plain() { local out; out=$(mktemp "$tmp/plain.XXXXXX"); find "$@" -name '*.yaml' -exec sh -c 'cat "$1"; echo ---' _ {} \; >"$out"; echo "$out"; }

# --- hub (platform-mgmt) ---------------------------------------------------------------------------------------------
# Argo passes the hub's API versions to helm, and charts gate on them (the cluster chart registers workers in
# OpenChoreo only while the hub serves openchoreo.dev). The hub serves every CRD its addons install: collect those
# first, then render every hub app with them (--api-versions group/version and group/version/Kind).
hubcrds=$tmp/hub-crds.yaml; : >"$hubcrds"
for f in $config/addons/management/*/addon.yaml; do
  read -r n c ns rel < <(yq '.addon | [.name, .chart, .namespace, .releaseName] | join(" ")' "$f")
  r=$(render "$rel" "$charts/$c" -n "$ns" --include-crds -f "$(dirname "$f")/values.yaml")
  yq 'select(.kind == "CustomResourceDefinition")' "$r" >>"$hubcrds"; echo --- >>"$hubcrds"
done
apiv=()
while read -r gv; do apiv+=(--api-versions "$gv"); done < <(yq -N 'select(.kind == "CustomResourceDefinition")
  | .spec.group as $g | .spec.names.kind as $k | .spec.versions[] | select(.served) | [$g + "/" + .name, $g + "/" + .name + "/" + $k] | .[]' \
  "$hubcrds" | sort -u)
[ ${#apiv[@]} -gt 100 ] || fail "hub API versions: only ${#apiv[@]} args"
for f in $config/addons/management/*/addon.yaml; do
  read -r n c ns rel < <(yq '.addon | [.name, .chart, .namespace, .releaseName] | join(" ")' "$f")
  r=$(render "$rel" "$charts/$c" -n "$ns" --include-crds -f "$(dirname "$f")/values.yaml" "${apiv[@]}")
  add "mgmt-$n" platform-mgmt in-cluster "$ns" "$r"
done
add fleet-base platform-mgmt in-cluster fleet "$(plain $config/fleet/base)"
add kargo-pipelines platform-mgmt in-cluster kargo "$(plain $config/kargo)"
for f in $config/fleet/clusters/*/*.yaml; do
  r=$(render "$(yq .name "$f")" $charts/cluster -n fleet -f "$f" "${apiv[@]}")
  add "cluster-$(yq .name "$f")" platform-mgmt in-cluster fleet "$r"
done
workers=()   # "<name> <env>" of every enabled worker cluster (role defaults to worker in the cluster chart)
for f in $config/fleet/clusters/*/*.yaml; do
  [ "$(yq '.role // "worker"' "$f")" = worker ] && workers+=("$(yq '.name + " " + .env' "$f")")
done
[ ${#workers[@]} -gt 0 ] || fail "no enabled worker cluster"

# --- workers (platform-workers, workloads) ---------------------------------------------------------------------------
for f in $config/addons/workers/*/addon.yaml; do
  d=$(dirname "$f"); a=$(basename "$d")
  # optional fields default to the folder name (kargo-pipeline and worker-addons do the same)
  read -r c ns rel < <(yq ".addon | [.chart // \"$a\", .namespace // \"$a\", .releaseName // \"$a\"] | join(\" \")" "$f")
  r=$(render "k-$a" $charts/kargo-pipeline --set kind=addon,name="$a",chart="$c",namespace="$ns",releaseName="$rel")
  add "kargo-addon-$a" platform-mgmt in-cluster kargo "$r"
  for w in "${workers[@]}"; do
    set -- $w
    v=(-f "$d/values.yaml"); [ -f "$d/envs/$2.values.yaml" ] && v+=(-f "$d/envs/$2.values.yaml")
    r=$(render "$rel" "$charts/$c" -n "$ns" --include-crds --skip-tests --kube-version 1.34.11 "${v[@]}")
    add "$a-$1" platform-workers "$1" "$ns" "$r"
  done
done
for f in repos/apps/*/app.yaml; do   # kargo-app-pipelines
  a=$(basename "$(dirname "$f")")
  r=$(render "k-$a" $charts/kargo-pipeline --set kind=app,name="$a",image="$(yq .image.repository "$f")")
  add "kargo-app-$a" platform-mgmt in-cluster kargo "$r"
done
for d in repos/apps/*/; do   # workloads (legacy until #17): every folder with a chart/
  a=$(basename "$d")
  [ -d "$d/chart" ] || continue
  for w in "${workers[@]}"; do
    set -- $w
    v=(); for x in "$d/envs/$2/values.yaml" "$d/clusters/$1/values.yaml"; do [ -f "$x" ] && v+=(-f "$x"); done
    r=$(render "$a-$1" "$d/chart" -n "$a" "${v[@]}")
    add "$a-$1" workloads "$1" "$a" "$r"
  done
done

# cluster-scoped = built-in list + every CRD rendered with scope Cluster
scoped=$tmp/cluster-kinds; tr ' ' '\n' <<<"$builtin_cluster" | grep . >"$scoped"
cat "$renders"/*.yaml | yq -N 'select(.kind == "CustomResourceDefinition" and .spec.scope == "Cluster")
  | .spec.group + "/" + .spec.names.kind' >>"$scoped"
while IFS=$'\t' read -r app proj cluster ns; do
  # "|"-joined: read collapses runs of whitespace IFS, and the core group is an empty first field
  yq -N 'select(.kind != null) | [(.apiVersion | sub("/?[^/]*$"; "")), .kind, (.metadata.namespace // "")] | join("|")' \
    "$renders/$app.$cluster.yaml" |
  while IFS='|' read -r g k n; do
    if grep -qxF "$g/$k" "$scoped"; then n=""; else n=${n:-$ns}; fi
    printf 'res\t%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "$proj" "$cluster" "$n" "$g" "$k"
  done >>"$recs"
done <"$tmp/apps.tsv"

# every source of every Application / ApplicationSet template under argocd/ (root is bootstrap's, project default)
for f in $config/argocd/*.yaml; do yq -o json -I0 '.' "$f"; done | jq -r 'select(.kind == "Application" or
  .kind == "ApplicationSet") | (.spec.template.spec // .spec) as $s | ([$s.source // empty] + ($s.sources // []))[]
  | ["src", "argocd/" + $s.project, $s.project, .repoURL] | @tsv' >>"$recs"

[ "$(grep -c '^res' "$recs")" -gt 500 ] || fail "suspiciously few rendered resources: $(grep -c '^res' "$recs")"
[ -z "${KEEP_RECORDS:-}" ] || cp "$recs" "$KEEP_RECORDS"
out=$(check "$recs") || fail "AppProjects reject what git deploys:
$out"

# Invariant 3: an Application template carries argocd-agent=true exactly when its project does (the principal ships
# both, or neither)
for f in $config/argocd/*.yaml; do yq -o json -I0 '.' "$f"; done | jq -r 'select(.kind == "Application" or
  .kind == "ApplicationSet") | (.spec.template // .) | [.metadata.name, .spec.project,
  (.metadata.labels["argocd-agent"] // "-")] | join("|")' |
while IFS='|' read -r app proj label; do
  want=$(yq "select(.metadata.name == \"$proj\") | .metadata.labels[\"argocd-agent\"] // \"-\"" "$projects")
  [ "$label" = "$want" ] || fail "$app: argocd-agent label '$label', its project $proj has '$want'"
done

# --- what the projects exist to reject -------------------------------------------------------------------------------
# rejects/admits "<record>": one record with | for tabs; the checker must refuse / accept it
rejects() { tr '|' '\t' <<<"$1" >"$tmp/one.tsv"; ! check "$tmp/one.tsv" >/dev/null || fail "admitted: $1"; }
admits() { tr '|' '\t' <<<"$1" >"$tmp/one.tsv"; check "$tmp/one.tsv" >/dev/null || fail "rejected: $1"; }
for p in platform-mgmt platform-workers workloads; do
  rejects "src|x|$p|https://github.com/someone/else.git"
  admits "src|x|$p|https://github.com/koorikla/platform-lab"          # Argo normalises the .git suffix away
done
# the hub is reachable only through platform-mgmt: a worker/app project Application can't target in-cluster
rejects 'dst|x|platform-workers|in-cluster|cert-manager'
rejects 'dst|x|workloads|in-cluster|podinfo'
rejects 'dst|x|platform-mgmt|dev1|cert-manager'
# a new worker cluster needs no project change (destination names are globs); a new namespace does
admits 'dst|x|platform-workers|prod-eu1|cert-manager'
admits 'dst|x|workloads|prod-eu1|podinfo'
rejects 'dst|x|platform-workers|dev1|argocd'
rejects 'res|x|platform-workers|dev1|argocd||Secret'
rejects 'dst|x|workloads|dev1|kube-system'
rejects 'res|x|workloads|dev1|kube-system||ConfigMap'
# cluster-scoped kinds: only what the renders above need
rejects 'res|x|workloads|dev1||rbac.authorization.k8s.io|ClusterRoleBinding'
rejects 'res|x|platform-workers|dev1||apiregistration.k8s.io|APIService'
rejects 'res|x|platform-mgmt|in-cluster||storage.k8s.io|StorageClass'
# CreateNamespace=true creates the namespace on a newborn worker, through the project's whitelist (gitops-engine
# autoCreateNamespace -> permission validator), though no live Application lists it once it exists
admits 'res|x|workloads|dev1|||Namespace'
admits 'res|x|platform-workers|dev1|||Namespace'
# the renders really exercise the lists: one namespace less and cert-manager's leader-election Roles are rejected
yq 'select(.metadata.name == "platform-workers") .spec.destinations |= map(select(.namespace != "kube-system"))' \
  "$projects" >"$tmp/tight.yaml"
out=$(check "$recs" "$tmp/tight.yaml") && fail "platform-workers without kube-system still admits every render"
grep -q 'cert-manager-dev1: rbac.authorization.k8s.io/Role in namespace kube-system' <<<"$out" || fail "tight: $out"

# --- project roles (Argo CD RBAC, #20) --------------------------------------------------------------------------------
# Project policies must name their own project (Argo CD's validatePolicy rejects the project otherwise).
yq -o json -I0 'select(.kind == "AppProject")' "$projects" | jq -r '.metadata.name as $p | (.spec.roles // [])[]
  | .name as $r | .policies[] | select(test("^p, proj:\($p):\($r), [a-z]+, [a-z/*]+, \($p)/[^,]+, (allow|deny)$") | not)
  | "\($p)/\($r): \(.)"' | grep . && fail "project role policies must be p, proj:<project>:<role>, <res>, <act>, <project>/<obj>"
if command -v argocd >/dev/null; then
  # what argocd-server enforces: the global argocd-rbac-cm policy + every project's roles (ProjectPoliciesString)
  pol=$tmp/policy.csv
  a=$(render argocd $charts/argo-cd -n argocd -f $config/addons/management/argo-cd/values.yaml)
  yq 'select(.kind == "ConfigMap" and .metadata.name == "argocd-rbac-cm") | .data["policy.csv"]' "$a" >"$pol"
  yq -o json -I0 'select(.kind == "AppProject")' "$projects" | jq -r '.metadata.name as $p | (.spec.roles // [])[]
    | "p, proj:\($p):\(.name), projects, get, \($p), allow", .policies[], (.groups[] as $g | "g, \($g), proj:\($p):\(.name)")' >>"$pol"
  while read -r want sub act res obj; do
    got=$({ argocd admin settings rbac can "$sub" "$act" "$res" "$obj" --policy-file "$pol" 2>/dev/null || true; } | tail -1)
    [ "$got" = "$want" ] || fail "rbac: $sub $act $res $obj = '$got', want $want"
  done <<'EOF'
Yes developers sync applications workloads/podinfo-dev1
Yes developers get applications workloads/podinfo-dev1
No developers create applications workloads/x
No developers update applications workloads/podinfo-dev1
No developers delete applications workloads/podinfo-dev1
No developers override applications workloads/podinfo-dev1
No developers action/apps/Deployment/restart applications workloads/podinfo-dev1
No developers sync applications platform-workers/cert-manager-dev1
No developers sync applications platform-mgmt/root
No developers update projects workloads
Yes sres sync applications workloads/podinfo-dev1
Yes sres sync applications platform-workers/cert-manager-dev1
Yes sres action/apps/Deployment/restart applications workloads/podinfo-dev1
Yes sres action/apps/Deployment/restart applications platform-workers/cert-manager-dev1
Yes sres get applications platform-mgmt/root
No sres sync applications platform-mgmt/root
No sres action/apps/Deployment/restart applications platform-mgmt/mgmt-kargo
No sres create applications workloads/x
No sres update applications platform-workers/cert-manager-dev1
No sres delete applications platform-workers/cert-manager-dev1
No sres override applications workloads/podinfo-dev1
No sres create exec platform-workers/cert-manager-dev1
No sres update applicationsets platform-workers/x
No sres update projects platform-workers
Yes platform-engineers sync applications workloads/podinfo-dev1
No someone-else sync applications workloads/podinfo-dev1
EOF
else
  echo "skip: argocd CLI not on PATH (project roles not evaluated)"
fi
