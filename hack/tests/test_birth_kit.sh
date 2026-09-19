#!/usr/bin/env bash
# CAAPH birth kit = umbrella chart platform-charts/worker-birth-kit (argo-cd worker profile + argocd-agent + ESO + the
# per-cluster OpenBao pull wiring), one Helm release per worker. CAAPH renders the HelmChartProxy valuesTemplate
# (clusterName: {{ .Cluster.metadata.name }}) per cluster; offline we pass dev1. Object-by-object equivalence with the
# four HelmChartProxies it replaced was checked in #52 (git history of this file).
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

# --- same versions as the hub (Renovate groups them)
[ "$(dep $kit external-secrets)" = "$(dep $charts/external-secrets external-secrets)" ] || fail "ESO: birth kit != hub"
[ "$(dep $kit argo-cd)" = "$(dep $charts/argo-cd argo-cd)" ] || fail "argo-cd: birth kit != hub"
[ ! -e $config/addons/workers/external-secrets ] || fail "ESO is birth kit now: remove addons/workers/external-secrets"

# --- clusterName: required, a DNS-1123 label (auth mount k8s-<name>, OpenBao path, agent identity)
# fails_with <message> <cmd...>: the command must fail with that message (not just any render error)
fails_with() {
  local out
  if out=$("${@:2}" 2>&1); then fail "line ${BASH_LINENO[0]}: expected failure: ${*:2}"; fi
  grep -qF -- "$1" <<<"$out" || fail "line ${BASH_LINENO[0]}: want error '$1', got: $out"
}
fails_with 'clusterName is required' helm template "$release" $kit -n "$ns"
fails_with 'clusterName "Dev_1" is not a DNS-1123 label' helm template "$release" $kit -n "$ns" --set clusterName=Dev_1
long=$(printf 'a%.0s' {1..64})
fails_with "clusterName \"$long\" is not a DNS-1123 label" helm template "$release" $kit -n "$ns" --set clusterName="$long"
fails_with 'external-secrets.namespaceOverride is required' \
  helm template "$release" $kit -n "$ns" --set clusterName=dev1 --set external-secrets.namespaceOverride=

# --- OpenBao pull wiring (store + TokenReview binding + agent identity)
css='select(.kind=="ClusterSecretStore")'
assert_yq "$o" "$css | .metadata.name" hub-openbao
assert_yq "$o" "$css | .spec.provider.vault.server" http://mgmt-lb:30820
assert_yq "$o" "$css | .spec.provider.vault.auth.kubernetes.mountPath" k8s-dev1
assert_yq "$o" "$css | .spec.provider.vault.auth.kubernetes.role" eso
assert_yq "$o" "$css | .spec.provider.vault.auth.kubernetes.serviceAccountRef | .namespace + \"/\" + .name" \
  external-secrets/external-secrets
assert_yq "$o" "$css | .spec.conditions[0].namespaces | join(\",\")" argocd
assert_yq "$o" 'select(.kind=="ClusterRoleBinding" and .metadata.name=="external-secrets-openbao-tokenreview") | .roleRef.name' \
  system:auth-delegator
assert_yq "$o" 'select(.metadata.name=="external-secrets-openbao-tokenreview") | .subjects[0] | .namespace + "/" + .name' \
  external-secrets/external-secrets
# the store's ServiceAccount is the one ESO really runs as
assert_yq "$o" 'select(.kind=="Deployment" and .metadata.name=="external-secrets") | .metadata.namespace + "/" + .spec.template.spec.serviceAccountName' \
  external-secrets/external-secrets
# agent identity: tls secret (type kubernetes.io/tls) + CA secret with ONLY ca.crt (the agent parses every key as a cert)
es='select(.kind=="ExternalSecret" and .metadata.name=="argocd-agent-client-tls")'
assert_yq "$o" "$es | .metadata.namespace" argocd
assert_yq "$o" "$es | .spec.target.template.type" kubernetes.io/tls
assert_yq "$o" "$es | [.spec.data[].secretKey] | sort | join(\",\")" tls.crt,tls.key
assert_yq "$o" "$es | [.spec.data[].remoteRef.key] | unique | join(\",\")" clusters/dev1/argocd-agent
ca='select(.kind=="ExternalSecret" and .metadata.name=="argocd-agent-ca")'
assert_yq "$o" "$ca | [.spec.data[].secretKey] | join(\",\")" ca.crt
assert_yq "$o" "$ca | .spec.data[0].remoteRef.key" clusters/dev1/argocd-agent
assert_yq "$o" '[select(.kind=="ExternalSecret") | .spec.secretStoreRef | .kind + "/" + .name] | unique | join(",")' \
  ClusterSecretStore/hub-openbao
# worker repo-servers clone from GitHub too: same CoreDNS override as the hub
assert_yq "$o" 'select(.kind=="ConfigMap" and .metadata.name=="coredns-custom") | .metadata.namespace' kube-system
[ "$(yq 'select(.kind=="ConfigMap" and .metadata.name=="coredns-custom") | .data["external.server"]' "$o")" = \
  "$(yq '.data["external.server"]' $config/fleet/base/hub-coredns.yaml)" ] ||
  fail "worker coredns-custom differs from fleet/base/hub-coredns.yaml"

# --- argocd-agent: v0.10.0 from quay, managed mode, dials the hub LB, heartbeat below the LB idle timeout
assert_yq "$o" 'select(.kind=="Deployment" and .metadata.name=="argocd-agent-agent-helm") | .spec.template.spec.containers[0].image' \
  quay.io/argoprojlabs/argocd-agent:v0.10.0
p='select(.kind=="ConfigMap" and .metadata.name=="argocd-agent-agent-helm-params") | .data'
assert_yq "$o" "$p | [\"agent.mode\", \"agent.creds\", \"agent.server.address\", \"agent.server.port\", \"agent.heartbeat.interval\",
  \"agent.redis.address\", \"agent.destination-based-mapping\", \"agent.create-namespace\", \"agent.allowed-namespaces\",
  \"agent.label-selector\", \"agent.tls.secret-name\", \"agent.tls.root-ca-secret-name\"] as \$k | [\$k[] as \$x | .[\$x]] | join(\" \")" \
  'managed mtls:any mgmt-lb 30443 30s argocd-redis:6379 true true * argocd-agent=true argocd-agent-client-tls argocd-agent-ca'
# one hub host for both hub endpoints (agent -> principal, ESO -> OpenBao)
[ "$(yq '.["argocd-agent-agent"].server' $kit/values.yaml)" = "$(yq '.hub.host' $kit/values.yaml)" ] ||
  fail "argocd-agent-agent.server != hub.host"

# --- argo-cd worker profile: application-controller + repo-server + redis only (ApplicationSets live on the hub)
assert_yq "$o" '[select(.kind=="Deployment" and (.metadata.name=="argocd-server" or .metadata.name=="argocd-applicationset-controller")) | .spec.replicas] | join(",")' 0,0
assert_yq "$o" '[select(.kind=="Deployment" or .kind=="StatefulSet") | select(.metadata.namespace=="argocd") | select(.spec.replicas != 0) | .metadata.name] | sort | join(",")' \
  argocd-agent-agent-helm,argocd-application-controller,argocd-redis,argocd-repo-server
# the argo-helm redis NetworkPolicy admits only Argo's own components: the agent needs redis too
np='select(.kind=="NetworkPolicy" and .metadata.name=="argocd-redis-allow-agent")'
assert_yq "$o" "$np | .spec.podSelector.matchLabels[\"app.kubernetes.io/name\"]" argocd-redis
assert_yq "$o" "$np | .spec.ingress[0].from[0].podSelector.matchLabels[\"app.kubernetes.io/name\"]" \
  "$(yq 'select(.kind=="Deployment" and .metadata.name=="argocd-agent-agent-helm") | .spec.template.metadata.labels["app.kubernetes.io/name"]' "$o")"

# --- ESO in its own namespace; its webhook must not block the store/ExternalSecrets created in the same install
assert_yq "$o" 'select(.kind=="Namespace") | .metadata.name' external-secrets
assert_yq "$o" '[select(.kind=="ValidatingWebhookConfiguration") | .webhooks[].failurePolicy] | unique | join(",")' Ignore

# --- crds/: bootstrap copies of the two ESO CRDs this chart instantiates. Helm installs crds/ before it maps the
# templates (else: "no matches for kind ClusterSecretStore"); the ownership metadata lets the same install adopt them
# as the subchart's templated CRDs, which then own upgrades. Must equal the pinned ESO version's CRDs.
crds=$(mktemp "$tmp/crds.XXXXXX"); cat $kit/crds/*.yaml > "$crds"
assert_yq "$crds" '[select(.kind != null) | .metadata.name] | sort | join(",")' \
  clustersecretstores.external-secrets.io,externalsecrets.external-secrets.io
assert_yq "$crds" '[select(.kind != null) | .metadata.labels["app.kubernetes.io/managed-by"] + " " +
  .metadata.annotations["meta.helm.sh/release-name"] + " " + .metadata.annotations["meta.helm.sh/release-namespace"]] | unique | join(",")' \
  "Helm $release $ns"
for n in clustersecretstores externalsecrets; do
  want=$(yq "select(.kind==\"CustomResourceDefinition\" and .metadata.name==\"$n.external-secrets.io\") | .spec" "$o")
  got=$(yq "select(.kind != null and .metadata.name==\"$n.external-secrets.io\") | .spec" "$crds")
  [ -n "$want" ] && [ "$want" = "$got" ] ||
    fail "crds/: $n differs from external-secrets $(dep $kit external-secrets): run hack/birth-kit-crds.sh"
done

# --- Helm stores each release in one Secret (<1 MiB): base64(gzip(release JSON)) = chart templates + files (crds/),
# values and the rendered manifest (subcharts aren't stored). Same encoding as Helm's storage driver; 0.1.0: 522 KB
# (the release Secret on a k3d test cluster held the same).
helm install "$release" $kit -n "$ns" -f "$tmp/values.yaml" --dry-run=client -o json > "$tmp/release.json" ||
  fail "helm install --dry-run=client"
sz=$(gzip -9 < "$tmp/release.json" | base64 | wc -c)
[ "$sz" -lt 900000 ] || fail "release Secret would be ${sz}B: too close to the 1 MiB limit"
