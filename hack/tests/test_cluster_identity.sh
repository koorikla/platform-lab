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
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="PushSecret" or .kind=="Role" or .kind=="RoleBinding")] | length' 0
