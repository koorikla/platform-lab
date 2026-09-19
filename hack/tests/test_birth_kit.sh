#!/usr/bin/env bash
# CAAPH birth kit: ESO + the per-cluster OpenBao pull wiring land on every worker at birth (not via worker-addons).
# CAAPH's .Cluster context can't be rendered offline -> check the valuesTemplate text, then render bedag/raw with the
# cluster name substituted the way CAAPH would.
source "$(dirname "$0")/lib.sh"
hcps=$config/fleet/base/helmchartproxies.yaml
hcp() { yq "select(.kind==\"HelmChartProxy\" and .metadata.name==\"$1\") | $2" "$hcps"; }

# ESO at birth, same version as the hub
assert_yq "$hcps" 'select(.metadata.name=="worker-external-secrets") | .spec.version' \
  "$(yq '.dependencies[0].version' $charts/external-secrets/Chart.yaml)"
assert_yq "$hcps" 'select(.metadata.name=="worker-external-secrets") | .spec.valuesTemplate | from_yaml | .installCRDs' true
[ ! -e $config/addons/workers/external-secrets ] || fail "ESO is birth kit now: remove addons/workers/external-secrets"

# the bootstrap valuesTemplate stamps the cluster identity
vt=$(hcp worker-secret-bootstrap .spec.valuesTemplate)
grep -qF 'k8s-{{ .Cluster.metadata.name }}' <<<"$vt" || fail "bootstrap: mountPath must be k8s-{{ .Cluster.metadata.name }}"
grep -qF 'clusters/{{ .Cluster.metadata.name }}/argocd-agent' <<<"$vt" || fail "bootstrap: remote key must be clusters/{{ .Cluster.metadata.name }}/argocd-agent"

# render bedag/raw as CAAPH would for dev1
sed 's/{{ \.Cluster\.metadata\.name }}/dev1/g' <<<"$vt" > "$tmp/bootstrap-values.yaml"
o=$(render bootstrap raw --repo "$(hcp worker-secret-bootstrap .spec.repoURL)" \
  --version "$(hcp worker-secret-bootstrap .spec.version)" -n argocd -f "$tmp/bootstrap-values.yaml")
assert_yq "$o" '[select(.kind != null)] | length' 5
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .metadata.name' hub-openbao
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.server' http://mgmt-lb:30820
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.auth.kubernetes.mountPath' k8s-dev1
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.auth.kubernetes.role' eso
assert_yq "$o" 'select(.kind=="ClusterRoleBinding") | .roleRef.name' system:auth-delegator
assert_yq "$o" 'select(.kind=="ClusterRoleBinding") | .subjects[0].namespace + "/" + .subjects[0].name' external-secrets/external-secrets
# agent identity: tls secret (type kubernetes.io/tls) + CA secret with ONLY ca.crt (the agent parses every key as a cert)
es='select(.kind=="ExternalSecret" and .metadata.name=="argocd-agent-client-tls")'
assert_yq "$o" "$es | .metadata.namespace" argocd
assert_yq "$o" "$es | .spec.target.template.type" kubernetes.io/tls
assert_yq "$o" "$es | [.spec.data[].secretKey] | sort | join(\",\")" tls.crt,tls.key
assert_yq "$o" "$es | [.spec.data[].remoteRef.key] | unique | join(\",\")" clusters/dev1/argocd-agent
ca='select(.kind=="ExternalSecret" and .metadata.name=="argocd-agent-ca")'
assert_yq "$o" "$ca | [.spec.data[].secretKey] | join(\",\")" ca.crt
assert_yq "$o" "$ca | .spec.data[0].remoteRef.key" clusters/dev1/argocd-agent
# worker repo-servers clone from GitHub too: same CoreDNS override as the hub
assert_yq "$o" 'select(.kind=="ConfigMap" and .metadata.name=="coredns-custom") | .metadata.namespace' kube-system
[ "$(yq 'select(.kind=="ConfigMap") | .data["external.server"]' "$o")" = "$(yq '.data["external.server"]' $config/fleet/base/hub-coredns.yaml)" ] ||
  fail "worker coredns-custom differs from fleet/base/hub-coredns.yaml"
