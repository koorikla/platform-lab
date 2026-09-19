#!/usr/bin/env bash
# OpenBao on the hub: dev-mode server, API on NodePort 30820 (workers reach it via mgmt-lb), hub-writer ClusterSecretStore
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
assert_yq "$o" '[select(.kind=="StatefulSet")] | length' 1
# only the API port is published (the chart Service also carries 8201, cluster-internal)
assert_yq "$o" '[select(.kind=="Service" and .spec.type=="NodePort")] | length' 1
assert_yq "$o" 'select(.kind=="Service" and .spec.type=="NodePort") | [.spec.ports[] | .port + ":" + .nodePort] | join(",")' 8200:30820
assert_yq "$o" 'select(.kind=="Service" and .spec.type=="NodePort") | .spec.selector | to_entries | map(.key + "=" + .value) | sort | join(",")' \
  "$(yq 'select(.kind=="StatefulSet") | .spec.selector.matchLabels | to_entries | map(.key + "=" + .value) | sort | join(",")' "$o")"
# ... and mgmt-lb forwards 30820 to it
lb=$(yq '.data.value' $config/fleet/base/hub-lb.yaml)
grep -qE '^ *bind \*:30820$' <<<"$lb" || fail "hub-lb.yaml: no frontend bound to :30820"
grep -qF 'JoinHostPort $backend.Address "30820"' <<<"$lb" || fail "hub-lb.yaml: no backend on node port 30820"
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .metadata.name' openbao
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.server' http://openbao.openbao.svc:8200
assert_yq "$o" 'select(.kind=="ClusterSecretStore") | .spec.provider.vault.auth.kubernetes.role' hub-writer
# no root token literal in git: dev mode generates one per start (kept in the pod's ~/.vault-token for postStart)
assert_yq "$o" 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].env[] | select(.name=="VAULT_DEV_ROOT_TOKEN_ID") | (.value // "") | length' 0
# postStart seeds the roles the hub-writer store and the fleet-sync CronJob log in with
assert_yq "$o" 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].lifecycle.postStart.exec.command[2] | [test("role/hub-writer"), test("role/fleet-sync")] | all' true
