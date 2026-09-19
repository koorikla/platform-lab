#!/usr/bin/env bash
# The only imperative entrypoint. CAPI pivot, then GitOps:
#   1. k3d "bootstrap" (throw-away) + CAPI stack        -> creates Cluster "mgmt" from fleet/clusters/mgmt/mgmt.yaml
#   2. same CAPI stack on mgmt, `clusterctl move`        -> mgmt manages itself (self-hosted), bootstrap deleted
#   3. Argo CD + root app on mgmt                        -> GitOps adopts everything above, incl. its own Cluster
# CAPI components are rendered from the same umbrella charts + values that Argo CD uses afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

HUB=mgmt BOOT=k3d-bootstrap
charts=repos/platform-charts
config=repos/platform-config
for bin in docker k3d kubectl helm clusterctl; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# helm template | kubectl apply, retried: CRDs, webhooks and cert-manager CA injection settle in any order.
apply_chart() {  # ctx release chart namespace
  local ctx=$1 rel=$2 chart=$3 ns=$4 vals=$config/addons/management/$2/values.yaml
  helm dependency build "$charts/$chart" >/dev/null
  kubectl --context "$ctx" create namespace "$ns" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f - >/dev/null
  for _ in $(seq 1 30); do
    helm template "$rel" "$charts/$chart" -n "$ns" --no-hooks -f "$vals" |
      kubectl --context "$ctx" apply --server-side --force-conflicts -f - >/dev/null 2>&1 && return 0
    sleep 10
  done
  helm template "$rel" "$charts/$chart" -n "$ns" --no-hooks -f "$vals" | kubectl --context "$ctx" apply --server-side -f -
}

install_capi() {  # ctx
  local ctx=$1
  apply_chart "$ctx" cert-manager cert-manager cert-manager
  kubectl --context "$ctx" -n cert-manager rollout status deploy --timeout=5m
  apply_chart "$ctx" capi-operator capi-operator capi-operator-system
  kubectl --context "$ctx" -n capi-operator-system rollout status deploy --timeout=5m
  apply_chart "$ctx" capi-providers capi-providers capi-system
  kubectl --context "$ctx" wait --for=condition=Ready --timeout=15m -A \
    coreproviders,bootstrapproviders,controlplaneproviders,infrastructureproviders,addonproviders --all
}

# Host access to the hub API: CAPD's kubeconfig points at the LB's docker-network IP; from the host use its published port.
hub_kubeconfig() {  # ctx holding Cluster mgmt
  local kc port; kc=$(mktemp)
  kubectl --context "$1" -n fleet get secret $HUB-kubeconfig -o jsonpath='{.data.value}' | base64 -d > "$kc"
  port=$(docker port $HUB-lb 6443/tcp | head -1 | awk -F: '{print $NF}')
  kubectl --kubeconfig "$kc" config set-cluster $HUB --server "https://127.0.0.1:$port" >/dev/null
  kubectl --kubeconfig "$kc" config rename-context "$HUB-admin@$HUB" $HUB >/dev/null
  KUBECONFIG="$kc:$HOME/.kube/config" kubectl config view --flatten > "$kc.merged"
  mv "$kc.merged" "$HOME/.kube/config" && chmod 600 "$HOME/.kube/config" && rm -f "$kc"
}
hub_server() {  # re-point an existing context after the LB's published port changed (docker restart)
  docker inspect $HUB-lb >/dev/null 2>&1 || return 0
  kubectl config set-cluster $HUB --server "https://127.0.0.1:$(docker port $HUB-lb 6443/tcp | head -1 | awk -F: '{print $NF}')" >/dev/null
}

hub_is_self_hosted() { kubectl --context $HUB -n fleet get cluster $HUB >/dev/null 2>&1; }

docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
kubectl config get-contexts $HUB >/dev/null 2>&1 && hub_server

if ! hub_is_self_hosted; then
  log "1/3 bootstrap cluster + CAPI"
  k3d cluster list bootstrap >/dev/null 2>&1 || k3d cluster create --config bootstrap/k3d-bootstrap.yaml --wait
  install_capi $BOOT
  kubectl --context $BOOT apply -f $config/fleet/base/namespace.yaml
  kubectl --context $BOOT apply -f $config/fleet/base/clusterclass-k3s-docker.yaml -f $config/fleet/base/hub-lb.yaml
  helm template $HUB $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml | kubectl --context $BOOT apply -f -

  log "2/3 waiting for the hub cluster, then pivot"
  until kubectl --context $BOOT -n fleet get secret $HUB-kubeconfig >/dev/null 2>&1; do sleep 10; done
  hub_kubeconfig $BOOT
  until kubectl --context $HUB get nodes >/dev/null 2>&1; do sleep 10; done
  kubectl --context $HUB wait node --all --for=condition=Ready --timeout=15m
  kubectl --context $BOOT -n fleet wait cluster/$HUB --for=condition=Available --timeout=20m
  install_capi $HUB
  clusterctl move -n fleet --kubeconfig-context $BOOT --to-kubeconfig "$HOME/.kube/config" --to-kubeconfig-context $HUB
  k3d cluster delete bootstrap
fi

log "3/3 Argo CD + root app"
kubectl config use-context $HUB >/dev/null
helm dependency build $charts/argo-cd >/dev/null
# Chart defaults only. Hub-specific values (redis proxy for argocd-agent etc.) arrive via GitOps.
helm upgrade --install argocd $charts/argo-cd --kube-context $HUB \
  --namespace argocd --create-namespace --wait --timeout 10m
kubectl --context $HUB apply -f bootstrap/root-app.yaml

echo
echo "Hub     : kubectl --context $HUB ...   (self-hosted: kubectl --context $HUB -n fleet get cluster $HUB)"
echo "UIs     : make ui   -> Argo CD http://localhost:8080 (admin / \$(make argocd-password)), Kargo http://localhost:8081 (admin / \$(make kargo-password))"
echo "Watch   : kubectl --context $HUB get applications -n argocd -w"
