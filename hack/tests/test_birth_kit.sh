#!/usr/bin/env bash
# CAAPH birth kit = umbrella chart platform-charts/worker-birth-kit (argo-cd worker profile + argocd-agent + ESO + the
# per-cluster OpenBao pull wiring), one Helm release per worker. CAAPH renders the HelmChartProxy valuesTemplate
# (clusterName: {{ .Cluster.metadata.name }}) per cluster; offline we pass dev1. Object-by-object equivalence with the
# four HelmChartProxies it replaced was checked in #52 (git history of this file).
# What the chart renders for a cluster: its unit tests (repos/platform-charts/worker-birth-kit/tests/). Here: the
# HelmChartProxy that installs it, whole-render sets, what it shares with the hub, its crds/ copies, release size.
source "$(dirname "$0")/lib.sh"
kit=$charts/worker-birth-kit
hcps=$config/fleet/base/helmchartproxies.yaml
dep() { yq ".dependencies[] | select(.name==\"$2\") | .version" "$1/Chart.yaml"; }

# --- the one HelmChartProxy: the published kit at the chart's current version, identity from the CAPI Cluster
assert_yq "$hcps" '[select(.kind=="HelmChartProxy") | .metadata.name] | join(",")' worker-birth-kit
h='select(.kind=="HelmChartProxy")'
assert_yq "$hcps" "$h | .spec.clusterSelector.matchLabels[\"platform.lab/role\"]" worker
assert_yq "$hcps" "$h | .spec.repoURL + \"/\" + .spec.chartName" oci://ghcr.io/koorikla/platform-charts/worker-birth-kit
assert_yq "$hcps" "$h | .spec.version" "$(yq '.version' $kit/Chart.yaml)"
assert_yq "$hcps" "$h | .spec.valuesTemplate" 'clusterName: {{ .Cluster.metadata.name }}'
release=$(yq "$h | .spec.releaseName" "$hcps")
ns=$(yq "$h | .spec.namespace" "$hcps")
[ "$ns" = argocd ] || fail "HCP namespace $ns: the agent and argo-cd live in argocd"
# The first install relies on Helm's default path: crds/ installed first, then templates adopted by ownership metadata.
# skipCRDs would drop crds/ ("no matches for kind"); includeCRDs / takeOwnership change how CRDs and existing objects
# are handled -> none of them, until re-verified.
assert_yq "$hcps" "$h | .spec.options | [.skipCRDs, .install.includeCRDs, .takeOwnership] | map(select(. != null)) | length" 0
# CAAPH renders valuesTemplate per cluster; offline: substitute dev1 the same way
yq "$h | .spec.valuesTemplate" "$hcps" | sed 's/{{ \.Cluster\.metadata\.name }}/dev1/g' > "$tmp/values.yaml"
o=$(render "$release" $kit -n "$ns" -f "$tmp/values.yaml")

# the chart's unit tests use the same release name and namespace
for s in $kit/tests/*_test.yaml; do
  assert_yq "$s" '.release.name + "/" + .release.namespace' "$release/$ns"
done

# --- same versions as the hub (Renovate groups them)
[ "$(dep $kit external-secrets)" = "$(dep $charts/external-secrets external-secrets)" ] || fail "ESO: birth kit != hub"
[ "$(dep $kit argo-cd)" = "$(dep $charts/argo-cd argo-cd)" ] || fail "argo-cd: birth kit != hub"
[ ! -e $config/addons/workers/external-secrets ] || fail "ESO is birth kit now: remove addons/workers/external-secrets"

# --- whole render (per-template unit tests can't see what another template adds)
# every ExternalSecret / ClusterExternalSecret reads through the one per-cluster store
assert_yq "$o" '[select(.kind=="ExternalSecret" or .kind=="ClusterExternalSecret") | (.spec.externalSecretSpec // .spec) |
  .secretStoreRef | .kind + "/" + .name] | unique | join(",")' ClusterSecretStore/hub-openbao
# the one Namespace the kit creates is ESO's; openchoreo-data-plane belongs to Argo (addon, CreateNamespace)
assert_yq "$o" '[select(.kind=="Namespace") | .metadata.name] | join(",")' external-secrets
# argo-cd worker profile: exactly these workloads run in argocd (ApplicationSets and the UI live on the hub; any other
# component the argo-cd subchart can add - commit-server, redis-ha, dex, notifications - must fail here)
assert_yq "$o" '[select(.kind=="Deployment" or .kind=="StatefulSet") | select(.metadata.namespace=="argocd") | select(.spec.replicas != 0) | .metadata.name] | sort | join(",")' \
  argocd-agent-agent-helm,argocd-application-controller,argocd-redis,argocd-repo-server
# ...and the redis NetworkPolicy admits the agent's pods by the label the agent Deployment really sets
assert_yq "$o" 'select(.kind=="NetworkPolicy" and .metadata.name=="argocd-redis-allow-agent") | .spec.ingress[0].from[0].podSelector.matchLabels["app.kubernetes.io/name"]' \
  "$(yq 'select(.kind=="Deployment" and .metadata.name=="argocd-agent-agent-helm") | .spec.template.metadata.labels["app.kubernetes.io/name"]' "$o")"

# --- worker repo-servers clone from GitHub too: same CoreDNS override as the hub
[ "$(yq 'select(.kind=="ConfigMap" and .metadata.name=="coredns-custom") | .data["external.server"]' "$o")" = \
  "$(yq '.data["external.server"]' $config/fleet/base/hub-coredns.yaml)" ] ||
  fail "worker coredns-custom differs from fleet/base/hub-coredns.yaml"

# --- one hub host for both hub endpoints (agent -> principal, ESO -> OpenBao); subchart values can't reference it
[ "$(yq '.["argocd-agent-agent"].server' $kit/values.yaml)" = "$(yq '.hub.host' $kit/values.yaml)" ] ||
  fail "argocd-agent-agent.server != hub.host"

# --- crds/: bootstrap copies of the three ESO CRDs this chart instantiates. Helm installs crds/ before it maps the
# templates (else: "no matches for kind ClusterSecretStore"); the ownership metadata lets the same install adopt them
# as the subchart's templated CRDs, which then own upgrades. Must equal the pinned ESO version's CRDs.
crds=$(mktemp "$tmp/crds.XXXXXX"); cat $kit/crds/*.yaml > "$crds"
assert_yq "$crds" '[select(.kind != null) | .metadata.name] | sort | join(",")' \
  clusterexternalsecrets.external-secrets.io,clustersecretstores.external-secrets.io,externalsecrets.external-secrets.io
assert_yq "$crds" '[select(.kind != null) | .metadata.labels["app.kubernetes.io/managed-by"] + " " +
  .metadata.annotations["meta.helm.sh/release-name"] + " " + .metadata.annotations["meta.helm.sh/release-namespace"]] | unique | join(",")' \
  "Helm $release $ns"
for n in clusterexternalsecrets clustersecretstores externalsecrets; do
  want=$(yq "select(.kind==\"CustomResourceDefinition\" and .metadata.name==\"$n.external-secrets.io\") | .spec" "$o")
  got=$(yq "select(.kind != null and .metadata.name==\"$n.external-secrets.io\") | .spec" "$crds")
  [ -n "$want" ] && [ "$want" = "$got" ] ||
    fail "crds/: $n differs from external-secrets $(dep $kit external-secrets): run hack/birth-kit-crds.sh"
done

# --- Helm stores each release in one Secret (<1 MiB): base64(gzip(release JSON)) = chart templates + files (crds/),
# values and the rendered manifest (subcharts aren't stored). Same encoding as Helm's storage driver; 0.1.0: 522 KB
# (the release Secret on a k3d test cluster held the same), 0.2.0: 547 KB.
helm install "$release" $kit -n "$ns" -f "$tmp/values.yaml" --dry-run=client -o json > "$tmp/release.json" ||
  fail "helm install --dry-run=client"
sz=$(gzip -9 < "$tmp/release.json" | base64 | wc -c)
[ "$sz" -lt 900000 ] || fail "release Secret would be ${sz}B: too close to the 1 MiB limit"
