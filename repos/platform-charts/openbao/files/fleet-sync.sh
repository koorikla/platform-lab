#!/usr/bin/env bash
# fleet-sync: one OpenBao kubernetes auth mount per worker cluster, so that cluster's ESO can log in with its own
# ServiceAccount and read secret/data/clusters/<name>/* - and nothing else. Idempotent; runs as a hub CronJob.
#   auth/k8s-<name>          kubernetes_host + CA from the CAPI kubeconfig; disable_local_ca_jwt: the client's own JWT
#                            is the TokenReview reviewer (the worker binds system:auth-delegator to its ESO SA)
#   auth/k8s-<name>/role/eso bound to $ESO_NS/$ESO_SA, policy cluster-<name>
#   policy cluster-<name>    read secret/data/clusters/<name>/*
# Mounts and policies of clusters that no longer exist are removed. DRY_RUN=1 prints writes instead of doing them.
set -euo pipefail

BAO_ADDR=${BAO_ADDR:-http://openbao.openbao.svc:8200}
FLEET_NS=${FLEET_NS:-fleet}
WORKER_SELECTOR=${WORKER_SELECTOR:-platform.lab/role=worker}
ESO_SA=${ESO_SA:-external-secrets}
ESO_NS=${ESO_NS:-external-secrets}
TOKEN_TTL=${TOKEN_TTL:-1h}
SA_DIR=${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
DRY_RUN=${DRY_RUN:-0}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# bao <METHOD> <path> [json]: OpenBao HTTP API. GETs always run; under DRY_RUN writes go to stderr (CA redacted).
bao() {
  local method=$1 path=$2 body=${3:-}
  if [ "$DRY_RUN" = 1 ] && [ "$method" != GET ]; then
    echo "DRY_RUN: $method /v1/$path $(jq -c 'if has("kubernetes_ca_cert") then .kubernetes_ca_cert = "<redacted>" else . end' <<<"${body:-null}")" >&2
    return 0
  fi
  local args=(-sS --fail-with-body --max-time 20 -X "$method" -H "X-Vault-Token: $TOKEN")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' --data "$body")
  curl "${args[@]}" "$BAO_ADDR/v1/$path"
}

# login (also under DRY_RUN: reads need a token)
TOKEN=$(jq -n --arg jwt "$(cat "$SA_DIR/token")" '{role: "fleet-sync", jwt: $jwt}' |
  curl -sS --fail-with-body --max-time 20 -X POST --data @- "$BAO_ADDR/v1/auth/kubernetes/login" | jq -er .auth.client_token)

clusters=$(kubectl get clusters.cluster.x-k8s.io -n "$FLEET_NS" -l "$WORKER_SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
mounts=$(bao GET sys/auth | jq -r '.data | keys[]')

for name in $clusters; do
  # a cluster that is still being born has no kubeconfig yet: skip, keep whatever exists, retry next run
  if ! kubectl get secret "$name-kubeconfig" -n "$FLEET_NS" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d > "$tmp/kc" ||
     [ ! -s "$tmp/kc" ]; then
    echo "skipped $name: no kubeconfig yet"
    continue
  fi
  server=$(kubectl config view --kubeconfig "$tmp/kc" --raw -o jsonpath='{.clusters[0].cluster.server}')
  ca=$(kubectl config view --kubeconfig "$tmp/kc" --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
  mount=k8s-$name

  grep -qx "$mount/" <<<"$mounts" ||
    bao POST "sys/auth/$mount" "$(jq -nc --arg d "worker $name (fleet-sync)" '{type: "kubernetes", description: $d}')" >/dev/null
  # always rewritten: a reborn cluster has a new CA and possibly a new LB address
  bao POST "auth/$mount/config" "$(jq -nc --arg h "$server" --arg ca "$ca" \
    '{kubernetes_host: $h, kubernetes_ca_cert: $ca, disable_local_ca_jwt: true}')" >/dev/null
  bao PUT "sys/policies/acl/cluster-$name" "$(jq -nc --arg p "path \"secret/data/clusters/$name/*\" { capabilities = [\"read\"] }" \
    '{policy: $p}')" >/dev/null
  bao POST "auth/$mount/role/eso" "$(jq -nc --arg sa "$ESO_SA" --arg ns "$ESO_NS" --arg p "cluster-$name" --arg ttl "$TOKEN_TTL" \
    '{bound_service_account_names: [$sa], bound_service_account_namespaces: [$ns], token_policies: [$p], token_ttl: $ttl}')" >/dev/null
  echo "ensured $mount server=$server"
done

# garbage: mounts/policies whose cluster is gone (CAPI Cluster deleted). A cluster being born is in $clusters -> kept.
for mount in $(grep '^k8s-' <<<"$mounts" | sed 's#/$##' || true); do
  grep -qx "${mount#k8s-}" <<<"$clusters" && continue
  bao DELETE "sys/auth/$mount" >/dev/null
  echo "removed $mount"
done
for policy in $(bao GET 'sys/policies/acl?list=true' | jq -r '.data.keys[]' | grep '^cluster-' || true); do
  grep -qx "${policy#cluster-}" <<<"$clusters" && continue
  bao DELETE "sys/policies/acl/$policy" >/dev/null
  echo "removed policy $policy"
done
