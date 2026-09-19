#!/usr/bin/env bash
# The only imperative entrypoint. CAPI pivot, then GitOps:
#   1. k3d "bootstrap" (throw-away) + CAPI stack        -> creates Cluster "mgmt" from fleet/clusters/mgmt/mgmt.yaml
#   2. same CAPI stack on mgmt, `clusterctl move`        -> mgmt manages itself (self-hosted), bootstrap deleted
#   3. Argo CD + root app on mgmt                        -> GitOps adopts everything above, incl. its own Cluster
# CAPI components are rendered from the same umbrella charts + values that Argo CD uses afterwards.
#
#   bootstrap.sh [up]   resumable: detects the stage the machine is in and runs only the remaining steps
#   bootstrap.sh stage  prints "<stage>: <remaining steps>" (read-only)
#   bootstrap.sh down   workers via CAPI (waits for their containers), then the hub's containers by CAPD label
# Knobs (seconds): POLL (between checks, 10), HUB_TIMEOUT (hub machines/API, 1200), DOWN_TIMEOUT (workers gone, 900),
# KARGO_WAIT (Kargo installed by Argo before the deploy key, 900).
# FORCE=1: down removes worker containers by label when CAPI can't. INIT_BRANCHES / DEPLOY_KEY: post-step scripts.
set -euo pipefail
cd "$(dirname "$0")/.."

HUB=mgmt BOOT=k3d-bootstrap
charts=repos/platform-charts
config=repos/platform-config
POLL=${POLL:-10} HUB_TIMEOUT=${HUB_TIMEOUT:-1200} DOWN_TIMEOUT=${DOWN_TIMEOUT:-900} KARGO_WAIT=${KARGO_WAIT:-900}
INIT_BRANCHES=${INIT_BRANCHES:-hack/init-rendered-branches.sh} DEPLOY_KEY=${DEPLOY_KEY:-hack/kargo-deploy-key.sh}
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
# poll <seconds> <cmd...>: true once cmd succeeds, false after ~seconds
poll() {
  local tries=$(( $1 / (POLL > 0 ? POLL : 1) )); shift
  [ "$tries" -ge 1 ] || tries=1
  while [ "$tries" -gt 0 ]; do "$@" && return 0; tries=$((tries - 1)); [ "$tries" -eq 0 ] || sleep "$POLL"; done
  return 1
}

# --- state probes (read-only) ------------------------------------------------------------------------------------
# The hub API is reached through mgmt-lb's published port, which changes when Docker restarts; --server overrides a
# stale context without touching ~/.kube/config (up re-points the context for good in hub_server).
hub_port() { docker port $HUB-lb 6443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}' || true; }
kh() {  # kubectl against the hub
  local p; p=$(hub_port)
  if [ -n "$p" ]; then kubectl --context $HUB --request-timeout=10s --server "https://127.0.0.1:$p" "$@"
  else kubectl --context $HUB --request-timeout=10s "$@"; fi
}
kb() { kubectl --context $BOOT --request-timeout=10s "$@"; }   # kubectl against the k3d bootstrap cluster
hub_up()          { kh get --raw /readyz >/dev/null 2>&1; }
hub_self_hosted() { kh -n fleet get clusters.cluster.x-k8s.io $HUB >/dev/null 2>&1; }
argo_installed()  { [ -n "$(kh -n argocd get secret -l owner=helm,name=argocd,status=deployed -o name 2>/dev/null)" ]; }
boot_exists()     { k3d cluster list bootstrap >/dev/null 2>&1; }
boot_up()         { kb get --raw /readyz >/dev/null 2>&1; }
boot_has_hub()    { kb -n fleet get clusters.cluster.x-k8s.io $HUB >/dev/null 2>&1; }
containers()      { docker ps -aq --filter "label=io.x-k8s.kind.cluster=$1"; }   # CAPD labels every node and LB

# detect_stage: where a previous (partial) run left the machine. Order matters: the most advanced evidence wins.
detect_stage() {
  if boot_exists && ! boot_up; then echo bootstrap-stopped; return; fi   # can't see what it holds: start it first
  local boot=0 bhub=0; boot_exists && boot=1; [ $boot = 1 ] && boot_has_hub && bhub=1
  if hub_up && hub_self_hosted; then
    if [ $bhub = 1 ]; then echo pivot-partial   # interrupted move: objects on both sides
    elif argo_installed; then echo argo
    else echo pivoted; fi
  elif [ $bhub = 1 ]; then
    if hub_up; then echo hub-unpivoted; else echo hub-requested; fi
  elif [ -n "$(containers $HUB)" ]; then echo orphan   # hub containers nobody manages: never build a second hub
  elif [ $boot = 1 ]; then echo bootstrap
  else echo fresh; fi
}
# steps_for <stage>: the steps still to run; drop-bootstrap only while a bootstrap cluster exists or will exist
steps_for() {
  local drop=''; boot_exists && drop='drop-bootstrap'
  case $1 in
    fresh|bootstrap)             echo "bootstrap-cluster bootstrap-capi hub-capi pivot drop-bootstrap argo root-app post" ;;
    bootstrap-stopped)           echo "start-bootstrap" ;;
    hub-requested|hub-unpivoted) echo "hub-capi pivot drop-bootstrap argo root-app post" ;;
    pivot-partial)               echo "pivot drop-bootstrap argo root-app post" ;;
    pivoted)                     echo "${drop:+$drop }argo root-app post" ;;
    argo)                        echo "${drop:+$drop }root-app post" ;;
    orphan)                      echo "-" ;;
  esac
}

# --- steps -------------------------------------------------------------------------------------------------------
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
  local kc; kc=$(mktemp)
  kubectl --context "$1" -n fleet get secret $HUB-kubeconfig -o jsonpath='{.data.value}' | base64 -d > "$kc"
  kubectl --kubeconfig "$kc" config set-cluster $HUB --server "https://127.0.0.1:$(hub_port)" >/dev/null
  kubectl --kubeconfig "$kc" config rename-context "$HUB-admin@$HUB" $HUB >/dev/null
  KUBECONFIG="$kc:$HOME/.kube/config" kubectl config view --flatten > "$kc.merged"
  mv "$kc.merged" "$HOME/.kube/config" && chmod 600 "$HOME/.kube/config" && rm -f "$kc"
}
hub_server() {  # re-point an existing context after the LB's published port changed (docker restart)
  local p; p=$(hub_port)
  [ -n "$p" ] || return 0
  kubectl config get-contexts $HUB >/dev/null 2>&1 || return 0
  kubectl config set-cluster $HUB --server "https://127.0.0.1:$p" >/dev/null
}

step_start_bootstrap() {
  log "starting the stopped bootstrap cluster"
  k3d cluster start bootstrap
  poll 300 boot_up || die "bootstrap cluster started but its API doesn't answer"
}
step_bootstrap_cluster() {
  log "bootstrap cluster (k3d)"
  boot_exists || k3d cluster create --config bootstrap/k3d-bootstrap.yaml --wait
}
step_bootstrap_capi() {
  log "CAPI on the bootstrap cluster, request the hub"
  install_capi $BOOT
  kb apply -f $config/fleet/base/namespace.yaml
  kb apply -f $config/fleet/base/clusterclass-k3s-docker.yaml -f $config/fleet/base/hub-lb.yaml
  helm template $HUB $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml | kb apply -f -
}
step_hub_capi() {
  log "waiting for the hub cluster, then CAPI on it"
  poll "$HUB_TIMEOUT" kb -n fleet get secret $HUB-kubeconfig >/dev/null 2>&1 ||
    die "no $HUB-kubeconfig after ${HUB_TIMEOUT}s: kubectl --context $BOOT -n fleet get cluster,machines"
  hub_lb() { [ -n "$(hub_port)" ]; }
  poll "$HUB_TIMEOUT" hub_lb || die "container $HUB-lb publishes no 6443 after ${HUB_TIMEOUT}s"
  hub_kubeconfig $BOOT
  poll "$HUB_TIMEOUT" kubectl --context $HUB get nodes >/dev/null 2>&1 || die "hub API not answering after ${HUB_TIMEOUT}s"
  kubectl --context $HUB wait node --all --for=condition=Ready --timeout=15m
  kb -n fleet wait cluster/$HUB --for=condition=Available --timeout=20m
  install_capi $HUB
}
step_pivot() {
  # move tolerates objects that already exist on the target, so re-running an interrupted move is supported upstream
  log "clusterctl move: the hub manages itself"
  clusterctl move -n fleet --kubeconfig-context $BOOT --to-kubeconfig "$HOME/.kube/config" --to-kubeconfig-context $HUB
}
step_drop_bootstrap() {
  log "deleting the bootstrap cluster"
  boot_exists || return 0
  hub_self_hosted || die "hub does not hold Cluster $HUB: refusing to delete the bootstrap cluster"
  ! boot_has_hub || die "bootstrap still holds Cluster $HUB (move incomplete): re-run make up"
  k3d cluster delete bootstrap
}
step_argo() {
  log "Argo CD"
  kubectl config use-context $HUB >/dev/null
  helm dependency build $charts/argo-cd >/dev/null
  # Chart defaults only. Hub-specific values (redis proxy for argocd-agent etc.) arrive via GitOps. Only ever runs
  # before the first successful install: afterwards Argo CD manages itself and a helm upgrade would reset it.
  helm upgrade --install argocd $charts/argo-cd --kube-context $HUB \
    --namespace argocd --create-namespace --wait --timeout 10m
}
step_root_app() {
  log "root app"
  kh apply -f bootstrap/root-app.yaml
}
step_post() {
  log "rendered branches + Kargo git credential"
  local notes=()
  "$INIT_BRANCHES" || { warn "$INIT_BRANCHES failed"; notes+=("rendered/* branches: fix git push access, then run $INIT_BRANCHES"); }
  if ! gh auth status >/dev/null 2>&1; then
    notes+=("Kargo deploy key: gh auth login && $DEPLOY_KEY")
  elif kh -n kargo-shared-resources get secret git-platform-lab >/dev/null 2>&1; then
    echo "Kargo git credential present: keeping it (run $DEPLOY_KEY to rotate)"
  elif poll "$KARGO_WAIT" kh get namespace kargo-shared-resources >/dev/null 2>&1; then
    "$DEPLOY_KEY" || notes+=("Kargo deploy key failed: re-run $DEPLOY_KEY")
  else
    notes+=("Kargo not installed yet (namespace kargo-shared-resources): run $DEPLOY_KEY once it is")
  fi
  echo
  echo "Hub     : kubectl --context $HUB ...   (self-hosted: kubectl --context $HUB -n fleet get cluster $HUB)"
  echo "UIs     : make ui   -> Argo CD http://localhost:8080 (admin / \$(make argocd-password)), Kargo http://localhost:8081 (admin / \$(make kargo-password))"
  echo "Watch   : kubectl --context $HUB get applications -n argocd -w"
  echo "Check   : make doctor"
  local n; for n in ${notes[@]+"${notes[@]}"}; do echo "TODO    : $n"; done
}

up() {
  local bin stage steps s
  for bin in docker k3d kubectl helm clusterctl; do command -v "$bin" >/dev/null || die "missing: $bin"; done
  docker network inspect kind >/dev/null 2>&1 || docker network create kind >/dev/null
  hub_server
  stage=$(detect_stage)
  if [ "$stage" = bootstrap-stopped ]; then step_start_bootstrap; stage=$(detect_stage); fi
  [ "$stage" != orphan ] || die "containers of '$HUB' exist but neither the hub API nor a bootstrap cluster holding \
Cluster $HUB answers. Nothing can resume that: run 'make down' (FORCE=1 if it asks), then 'make up'."
  steps=$(steps_for "$stage")
  log "stage: $stage -> $steps"
  for s in $steps; do "step_${s//-/_}"; done
}

down() {
  local workers='' w leftover='' names
  hub_server
  if hub_up; then
    workers=$(kh -n fleet get clusters.cluster.x-k8s.io -l platform.lab/role=worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -n "$workers" ]; then
      log "stopping Argo CD (it would recreate the worker Clusters), deleting workers via CAPI: $workers"
      kh -n argocd scale statefulset,deployment --all --replicas=0 >/dev/null 2>&1 || true
      kh -n fleet delete clusters.cluster.x-k8s.io -l platform.lab/role=worker --wait=false
      workers_gone() {
        for w in $workers; do
          ! kh -n fleet get clusters.cluster.x-k8s.io "$w" >/dev/null 2>&1 && [ -z "$(containers "$w")" ] || return 1
        done
      }
      poll "$DOWN_TIMEOUT" workers_gone || die "workers not gone after ${DOWN_TIMEOUT}s: kept the hub (Argo CD scaled \
to 0) so CAPI can finish (kubectl --context $HUB -n fleet get clusters,machines); re-run make down"
    fi
  else
    warn "hub API not reachable: worker Clusters can't be deleted through CAPI"
  fi
  # CAPD containers of any cluster this repo defines (enabled or not) that CAPI didn't clean up
  names=$(awk '/^name:/ {print $2}' $config/fleet/clusters/*/*.yaml* | grep -vx $HUB | sort -u || true)
  for w in $(printf '%s\n' $workers $names | sort -u); do [ -z "$(containers "$w")" ] || leftover="$leftover $w"; done
  if [ -n "$leftover" ]; then
    [ "${FORCE:-}" = 1 ] || die "containers of worker cluster(s)$leftover remain and CAPI can't remove them. \
Re-run with FORCE=1 to remove them by label io.x-k8s.kind.cluster=<name>."
    for w in $leftover; do log "removing containers of $w (FORCE=1)"; containers "$w" | xargs docker rm -f -v >/dev/null; done
  fi
  # before the hub: an unpivoted hub is owned by the bootstrap cluster's CAPD, which would recreate its machines
  if boot_exists; then log "deleting the bootstrap cluster"; k3d cluster delete bootstrap; fi
  # never `kind delete cluster`: kind would also list CAPD clusters; the label selects exactly the hub's containers
  for _ in 1 2 3; do
    [ -n "$(containers $HUB)" ] || break
    log "removing the hub's containers (label io.x-k8s.kind.cluster=$HUB)"
    containers $HUB | xargs docker rm -f -v >/dev/null
  done
  [ -z "$(containers $HUB)" ] || die "containers of $HUB remain: docker ps -a --filter label=io.x-k8s.kind.cluster=$HUB"
  kubectl config delete-context $HUB >/dev/null 2>&1 || true
  kubectl config delete-cluster $HUB >/dev/null 2>&1 || true
  kubectl config delete-user $HUB-admin >/dev/null 2>&1 || true
  log "lab removed"
}

case ${1:-up} in
  up) up ;;
  down) down ;;
  stage) s=$(detect_stage); echo "$s: $(steps_for "$s")" ;;
  *) echo "usage: $0 [up|stage|down]" >&2; exit 2 ;;
esac
