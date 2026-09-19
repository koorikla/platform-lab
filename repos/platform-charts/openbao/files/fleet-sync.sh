#!/usr/bin/env bash
# fleet-sync: one OpenBao kubernetes auth mount per worker cluster, so that cluster's ESO can log in with its own
# ServiceAccount and read secret/data/clusters/<name>/* - and nothing else. Idempotent; runs as a hub CronJob.
#   auth/k8s-<name>          kubernetes_host = CAPI Cluster .spec.controlPlaneEndpoint, CA = Secret <name>-ca-public in
#                            $CA_NS (ca.crt only, projected by the cluster chart); disable_local_ca_jwt: the client's own
#                            JWT is the TokenReview reviewer (the worker binds system:auth-delegator to its ESO SA)
#   auth/k8s-<name>/role/eso bound to $ESO_NS/$ESO_SA, policy cluster-<name>
#   policy cluster-<name>    read secret/data/clusters/<name>/*
# Mounts and policies of clusters that no longer exist are removed. One failing cluster doesn't stop the others (exit 1
# at the end). DRY_RUN=1 prints writes instead of doing them. Parameter shapes (plain strings, no lists) are what the
# fleet-sync policy's allowed_parameters accept - see server.postStart in values.yaml.
set -euo pipefail

BAO_ADDR=${BAO_ADDR:-http://openbao.openbao.svc:8200}
FLEET_NS=${FLEET_NS:-fleet}
CA_NS=${CA_NS:-openbao}
WORKER_SELECTOR=${WORKER_SELECTOR:-platform.lab/role=worker}
ESO_SA=${ESO_SA:-external-secrets}
ESO_NS=${ESO_NS:-external-secrets}
TOKEN_TTL=${TOKEN_TTL:-1h}
SA_DIR=${SA_DIR:-/var/run/secrets/kubernetes.io/serviceaccount}
DRY_RUN=${DRY_RUN:-0}
umask 077
tmp=$(mktemp -d)
auth=$tmp/auth                     # "X-Vault-Token: ..." header file: the token never shows up in argv
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ ! -s "$auth" ] || curl -sS -o /dev/null --max-time 5 -X POST -H @"$auth" "$BAO_ADDR/v1/auth/token/revoke-self" || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# bao <METHOD> <path> [json]: OpenBao HTTP API. GETs always run; under DRY_RUN writes go to stderr (CA redacted).
bao() {
  local method=$1 path=$2 body=${3:-}
  if [ "$DRY_RUN" = 1 ] && [ "$method" != GET ]; then
    echo "DRY_RUN: $method /v1/$path $(jq -c 'if has("kubernetes_ca_cert") then .kubernetes_ca_cert = "<redacted>" else . end' <<<"${body:-null}")" >&2
    return 0
  fi
  local args=(-sS --fail-with-body --max-time 20 -X "$method" -H @"$auth")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' --data "$body")
  curl "${args[@]}" "$BAO_ADDR/v1/$path"
}

# login (also under DRY_RUN: reads need a token); JWT via stdin, token straight into the header file
jq -n --rawfile jwt "$SA_DIR/token" '{role: "fleet-sync", jwt: ($jwt | rtrimstr("\n"))}' |
  curl -sS --fail-with-body --max-time 20 -X POST --data @- "$BAO_ADDR/v1/auth/kubernetes/login" |
  jq -er '"X-Vault-Token: " + .auth.client_token' > "$auth"

# "<name> <host> <port>" per worker; host/port stay empty until CAPI has an endpoint
clusters=$(kubectl get clusters.cluster.x-k8s.io -n "$FLEET_NS" -l "$WORKER_SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.controlPlaneEndpoint.host} {.spec.controlPlaneEndpoint.port}{"\n"}{end}')
names=$(awk 'NF {print $1}' <<<"$clusters")
mounts=$(bao GET sys/auth | jq -r '.data | keys[]')

sync_cluster() {
  local name=$1 host=${2:-} port=${3:-} ca mount=k8s-$1
  # a cluster that is still being born has no endpoint / projected CA yet: skip, keep whatever exists, retry next run
  if [ -z "$host" ] || [ -z "$port" ]; then echo "skipped $name: no controlPlaneEndpoint yet"; return 0; fi
  if ! ca=$(kubectl get secret "$name-ca-public" -n "$CA_NS" -o jsonpath='{.data.ca\.crt}' 2>/dev/null) || [ -z "$ca" ]; then
    echo "skipped $name: no $CA_NS/$name-ca-public yet"; return 0
  fi
  ca=$(base64 -d <<<"$ca")

  grep -qx "$mount/" <<<"$mounts" ||
    bao POST "sys/auth/$mount" "$(jq -nc --arg d "worker $name (fleet-sync)" '{type: "kubernetes", description: $d}')" >/dev/null
  # always rewritten: a reborn cluster has a new CA and possibly a new LB address
  bao POST "auth/$mount/config" "$(jq -nc --arg h "https://$host:$port" --arg ca "$ca" \
    '{kubernetes_host: $h, kubernetes_ca_cert: $ca, disable_local_ca_jwt: true}')" >/dev/null
  bao PUT "sys/policies/acl/cluster-$name" "$(jq -nc --arg p "path \"secret/data/clusters/$name/*\" { capabilities = [\"read\"] }" \
    '{policy: $p}')" >/dev/null
  bao POST "auth/$mount/role/eso" "$(jq -nc --arg sa "$ESO_SA" --arg ns "$ESO_NS" --arg p "cluster-$name" --arg ttl "$TOKEN_TTL" \
    '{bound_service_account_names: $sa, bound_service_account_namespaces: $ns, token_policies: $p, token_ttl: $ttl}')" >/dev/null
  echo "ensured $mount server=https://$host:$port"
}

rc=0
while read -r name host port; do
  [ -n "$name" ] || continue
  # errexit is ignored inside `f || ...`, so run each cluster in its own errexit subshell and collect the status
  set +e; (set -e; sync_cluster "$name" "$host" "$port"); st=$?; set -e
  [ "$st" = 0 ] || { echo "failed $name"; rc=1; }
done <<<"$clusters"

# garbage: mounts/policies whose cluster is gone (CAPI Cluster deleted). A cluster being born is listed -> kept.
# An empty list next to existing k8s-* mounts is more likely a broken lookup than a fleet that vanished: don't act.
k8s_mounts=$(grep '^k8s-' <<<"$mounts" | sed 's#/$##' || true)
if [ -z "$names" ] && [ -n "$k8s_mounts" ]; then
  echo "refusing cleanup: no worker clusters listed but $(wc -l <<<"$k8s_mounts" | tr -d ' ') k8s-* mounts exist (remove by hand if intended)"
  exit "$rc"
fi
for mount in $k8s_mounts; do
  grep -qx "${mount#k8s-}" <<<"$names" && continue
  if bao DELETE "sys/auth/$mount" >/dev/null; then echo "removed $mount"; else echo "failed removing $mount"; rc=1; fi
done
for policy in $(bao GET 'sys/policies/acl?list=true' | jq -r '.data.keys[]' | grep '^cluster-' || true); do
  grep -qx "${policy#cluster-}" <<<"$names" && continue
  if bao DELETE "sys/policies/acl/$policy" >/dev/null; then echo "removed policy $policy"; else echo "failed removing policy $policy"; rc=1; fi
done
exit "$rc"
