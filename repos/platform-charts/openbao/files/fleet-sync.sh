#!/usr/bin/env bash
# fleet-sync: one OpenBao kubernetes auth mount per worker cluster, so that cluster's ESO can log in with its own
# ServiceAccount and read secret/data/clusters/<name>/* - and nothing else. Idempotent; runs as a hub CronJob.
#   auth/k8s-<name>          kubernetes_host = CAPI Cluster .spec.controlPlaneEndpoint, CA = Secret <name>-ca-public in
#                            $CA_NS (ca.crt only, projected by the cluster chart); disable_local_ca_jwt: the client's own
#                            JWT is the TokenReview reviewer (the worker binds system:auth-delegator to its ESO SA)
#   entity cluster-<name>    metadata cluster=<name>, with an alias <ESO_NS>/<ESO_SA> on auth/k8s-<name>: every ESO login
#                            there is this entity
#   auth/k8s-<name>/role/eso bound to $ESO_NS/$ESO_SA, alias_name_source serviceaccount_name, policy cluster-reader:
#                            one fixed policy, templated on the entity's metadata (files/policies/cluster-reader.hcl)
# fleet-sync writes no policy. Mounts and entities of clusters that no longer exist are removed. One failing cluster
# doesn't stop the others (exit 1 at the end). DRY_RUN=1 prints writes instead of doing them. Parameter shapes (plain
# strings, no lists) are what the fleet-sync policy's allowed_parameters accept (templates/configure.yaml).
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
    # missing, or its name-scoped Role (cluster chart) not synced yet: both settle within minutes of a birth
    echo "skipped $name: no $CA_NS/$name-ca-public yet (or no get on it yet)"; return 0
  fi
  ca=$(base64 -d <<<"$ca")

  grep -qx "$mount/" <<<"$mounts" ||
    bao POST "sys/auth/$mount" "$(jq -nc --arg d "worker $name (fleet-sync)" '{type: "kubernetes", description: $d}')" >/dev/null
  # always rewritten: a reborn cluster has a new CA and possibly a new LB address
  bao POST "auth/$mount/config" "$(jq -nc --arg h "https://$host:$port" --arg ca "$ca" \
    '{kubernetes_host: $h, kubernetes_ca_cert: $ca, disable_local_ca_jwt: true}')" >/dev/null

  # identity before the role: no ESO login can happen yet, so none creates a stray entity (an alias upsert would move
  # it anyway). Both calls are upserts; the entity id and mount accessor are read back.
  local entity=cluster-$name id acc
  bao POST "identity/entity/name/$entity" "$(jq -nc --arg c "$name" '{metadata: {cluster: $c}}')" >/dev/null
  id=$(bao GET "identity/entity/name/$entity" | jq -er '.data.id') || id=
  acc=$(bao GET sys/auth | jq -r --arg m "$mount/" '.data[$m].accessor // empty')
  if [ "$DRY_RUN" = 1 ]; then id=${id:-<new entity>}; acc=${acc:-<new mount>}; fi
  [ -n "$id" ] && [ -n "$acc" ] || { echo "no entity id or accessor for $mount" >&2; return 1; }
  bao POST identity/entity-alias "$(jq -nc --arg n "$ESO_NS/$ESO_SA" --arg a "$acc" --arg i "$id" \
    '{name: $n, mount_accessor: $a, canonical_id: $i}')" >/dev/null

  bao POST "auth/$mount/role/eso" "$(jq -nc --arg sa "$ESO_SA" --arg ns "$ESO_NS" --arg ttl "$TOKEN_TTL" \
    '{bound_service_account_names: $sa, bound_service_account_namespaces: $ns, token_policies: "cluster-reader",
      token_ttl: $ttl, alias_name_source: "serviceaccount_name"}')" >/dev/null
  echo "ensured $mount server=https://$host:$port"
}

rc=0
while read -r name host port; do
  [ -n "$name" ] || continue
  # errexit is ignored inside `f || ...`, so run each cluster in its own errexit subshell and collect the status
  set +e; (set -e; sync_cluster "$name" "$host" "$port"); st=$?; set -e
  [ "$st" = 0 ] || { echo "failed $name"; rc=1; }
done <<<"$clusters"

# garbage: mounts/entities whose cluster is gone (CAPI Cluster deleted). A cluster being born is listed -> kept.
# An empty list next to existing k8s-* mounts is more likely a broken lookup than a fleet that vanished: don't act.
k8s_mounts=$(grep '^k8s-' <<<"$mounts" | sed 's#/$##' || true)
if [ -z "$names" ] && [ -n "$k8s_mounts" ]; then
  echo "refusing cleanup: no worker clusters listed but $(wc -l <<<"$k8s_mounts" | tr -d ' ') k8s-* mounts exist (remove by hand if intended)"
  exit "$rc"
fi
# entity first (its aliases go with it): if that fails the mount stays, so the next run retries both
for mount in $k8s_mounts; do
  grep -qx "${mount#k8s-}" <<<"$names" && continue
  if bao DELETE "identity/entity/name/cluster-${mount#k8s-}" >/dev/null && bao DELETE "sys/auth/$mount" >/dev/null; then
    echo "removed $mount"
  else
    echo "failed removing $mount"; rc=1
  fi
done
exit "$rc"
