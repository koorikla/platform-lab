#!/usr/bin/env bash
# OpenBao on the hub: dev-mode server, API on NodePort 30820 (workers reach it via mgmt-lb), hub-writer ClusterSecretStore
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
assert_yq "$o" '[select(.kind=="StatefulSet")] | length' 1
assert_yq "$o" 'select(.kind=="Service" and .spec.type=="NodePort") | .spec.ports[] | select(.port==8200) | .nodePort' 30820
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .metadata.name' openbao
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.server' http://openbao.openbao.svc:8200
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.auth.kubernetes.role' hub-writer
# no root token literal in git: dev mode generates one per start (kept in the pod's ~/.vault-token for postStart)
assert_yq "$o" 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].env[] | select(.name=="VAULT_DEV_ROOT_TOKEN_ID") | (.value // "") | length' 0
# postStart seeds the roles the hub-writer store and the fleet-sync CronJob log in with
assert_yq "$o" 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].lifecycle.postStart.exec.command[2] | [test("role/hub-writer"), test("role/fleet-sync")] | all' true
