#!/bin/sh
# configure: the hub's OpenBao configuration, applied idempotently by the `configure` sidecar of openbao-0 (every
# 5 min, 20 s after a failure). Replaces dev mode's postStart; self-init only bootstraps the login used here.
#   kv v2 at secret/, every *.hcl next to this script as a policy of that name,
#   and the hub roles below (each bound to exactly one ServiceAccount in this namespace).
# Per-worker mounts/entities are fleet-sync's (files/fleet-sync.sh). Nothing is deleted: a policy or role removed from
# the chart stays in OpenBao until removed by hand (break-glass: values.yaml header).
# Runs in the OpenBao image (bao CLI, busybox sh). The token lives only in this process's environment.
set -eu
CONF_DIR=${CONF_DIR:-/openbao/configure}
SA_DIR=${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
: "${BAO_K8S_NAMESPACE:?}" "${BAO_SA:?}"

# unauthenticated; 0 = initialised and unsealed (self-init completes before the listener opens)
bao status >/dev/null 2>&1 || { echo "configure: OpenBao sealed or unreachable, retrying"; exit 1; }
BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=openbao-config jwt=@"$SA_DIR/token")
export BAO_TOKEN
trap 'bao token revoke -self >/dev/null 2>&1 || true' EXIT

bao secrets list | grep -q '^secret/' || bao secrets enable -path=secret -version=2 kv >/dev/null
# auth/kubernetes/config is self-init's (values.yaml) and deliberately not rewritten here: a wrong value would lock out
# the very login this script depends on.

for f in "$CONF_DIR"/*.hcl; do
  bao policy write "$(basename "$f" .hcl)" "$f" >/dev/null
done

# this sidecar (same binding as the self-init bootstrap in values.yaml)
bao write auth/kubernetes/role/openbao-config token_policies=openbao-config token_ttl=10m \
  bound_service_account_names="$BAO_SA" bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
# ClusterSecretStore openbao: PushSecrets of per-cluster material
bao write auth/kubernetes/role/hub-writer token_policies=hub-writer token_ttl=1h \
  bound_service_account_names=openbao-hub-writer bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
# CronJob openbao-fleet-sync
bao write auth/kubernetes/role/fleet-sync token_policies=fleet-sync token_ttl=10m \
  bound_service_account_names=openbao-fleet-sync bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
# OpenChoreo: seeder PushSecrets write secret/openchoreo/*, ClusterSecretStore `default` reads it
bao write auth/kubernetes/role/openchoreo-seeder token_policies=openchoreo-seeder token_ttl=10m \
  bound_service_account_names=openbao-openchoreo-seeder bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
bao write auth/kubernetes/role/openchoreo-reader token_policies=openchoreo-reader token_ttl=1h \
  bound_service_account_names=openbao-openchoreo-reader bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
# humans (`make bao`): hand-written secret/hub/*
bao write auth/kubernetes/role/operator token_policies=operator token_ttl=30m \
  bound_service_account_names=openbao-operator bound_service_account_namespaces="$BAO_K8S_NAMESPACE" >/dev/null
echo "configure: applied"
