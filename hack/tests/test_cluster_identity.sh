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
assert_yq "$w" 'select(.kind=="ExternalSecret") | .spec.secretStoreRef.name' in-cluster
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="PushSecret")] | length' 0
