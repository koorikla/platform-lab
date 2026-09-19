#!/usr/bin/env bash
# worker: agent client cert + CA go to OpenBao (hub-local PushSecret, store openbao) - the worker pulls them itself.
# Nothing on the hub writes into a worker (no ClusterSecretStore with the CAPI kubeconfig). Hub: no agent identity.
source "$(dirname "$0")/lib.sh"
w=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$w" '[select(.kind=="PushSecret")] | length' 1
assert_yq "$w" 'select(.kind=="PushSecret") | .spec.secretStoreRefs[0].kind + "/" + .spec.secretStoreRefs[0].name' ClusterSecretStore/openbao
assert_yq "$w" 'select(.kind=="PushSecret") | [.spec.data[].match.remoteRef.remoteKey] | unique | join(",")' clusters/dev1/argocd-agent
assert_yq "$w" 'select(.kind=="PushSecret") | [.spec.data[].match.remoteRef.property] | sort | join(",")' ca.crt,tls.crt,tls.key
assert_yq "$w" '[select(.kind=="ClusterSecretStore")] | length' 0
# the hub Argo cluster secret stays (in-cluster store)
assert_yq "$w" 'select(.kind=="ExternalSecret" and .metadata.name=="cluster-dev1") | .spec.secretStoreRef.name' in-cluster
# worker API CA for fleet-sync: projector may get exactly dev1-ca; only its public cert lands in openbao
assert_yq "$w" 'select(.kind=="Role" and .metadata.namespace=="fleet") | .rules[0].resourceNames | join(",")' dev1-ca
assert_yq "$w" 'select(.kind=="Role" and .metadata.namespace=="fleet") | .rules[0].verbs | join(",")' get
assert_yq "$w" 'select(.kind=="RoleBinding" and .metadata.namespace=="fleet") | .subjects[0].namespace + "/" + .subjects[0].name' openbao/fleet-ca-projector
es='select(.kind=="ExternalSecret" and .metadata.name=="dev1-ca-public")'
assert_yq "$w" "$es | .metadata.namespace" openbao
assert_yq "$w" "$es | .spec.secretStoreRef.kind + \"/\" + .spec.secretStoreRef.name" SecretStore/fleet-ca
assert_yq "$w" "$es | [.spec.data[].secretKey] | join(\",\")" ca.crt
assert_yq "$w" "$es | .spec.data[0].remoteRef.key + \"#\" + .spec.data[0].remoteRef.property" dev1-ca#tls.crt
# rebirth (#68): CAPI mints a new <name>-ca; fleet-sync (every 2m) copies whatever this projection holds into
# auth/k8s-<name>, so it must follow the source within a minute. Periodic is the only ESO v2.10 policy that re-reads
# the source (OnChange = ExternalSecret spec changes only, CreatedOnce = never).
assert_yq "$w" "$es | .spec.refreshInterval" 1m
assert_yq "$w" "$es | .spec.refreshPolicy // \"Periodic\"" Periodic
# #30: fleet-sync may get exactly this projection in openbao (the namespace also holds the unseal key): one name-scoped
# Role per worker, bound to its SA; the name is the ExternalSecret's target
fs='select(.kind=="Role" and .metadata.namespace=="openbao")'
assert_yq "$w" "[$fs] | length" 1
assert_yq "$w" "$fs | .rules | length" 1
assert_yq "$w" "$fs | .rules[0] | (.resources | join(\",\")) + \":\" + (.verbs | join(\",\")) + \":\" + (.resourceNames | join(\",\"))" \
  "secrets:get:$(yq "$es | .spec.target.name" "$w")"
fsb='select(.kind=="RoleBinding" and .metadata.namespace=="openbao")'
assert_yq "$w" "$fsb | .roleRef.name" "$(yq "$fs | .metadata.name" "$w")"
assert_yq "$w" "$fsb | .subjects | map(.namespace + \"/\" + .name) | join(\",\")" openbao/openbao-fleet-sync
# the SA name is the openbao chart's (its CronJob runs as it)
ob=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
assert_yq "$ob" \
  'select(.kind=="CronJob" and .metadata.name=="openbao-fleet-sync") | .spec.jobTemplate.spec.template.spec.serviceAccountName' \
  "$(yq "$fsb | .subjects[0].name" "$w")"
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="PushSecret" or .kind=="Role" or .kind=="RoleBinding")] | length' 0
