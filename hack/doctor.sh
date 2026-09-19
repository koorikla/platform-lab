#!/usr/bin/env bash
# make doctor: can this machine run the lab, and how is the lab doing? Read-only.
# FAIL (exit 1) = a boot would break; WARN = degraded or needed later; INFO = state.
# Docker Desktop minimums: hub + 1 worker = 8 CPUs / 8 GB (below 8 GB: FAIL); the full lab (hub + dev1 + dev2 +
# OpenChoreo) = 12 CPUs / 16 GB (below: WARN) — measured in #76, where 12 CPUs were saturated during bursts.
# Knobs: MIN_DISK_GB (25), MIN_MEM_GB (8), FULL_MEM_GB (16), MIN_CPUS (8), FULL_CPUS (12), PROC_ROOT (/proc, for tests).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
HUB=mgmt MIN_DISK_GB=${MIN_DISK_GB:-25} MIN_MEM_GB=${MIN_MEM_GB:-8} PROC_ROOT=${PROC_ROOT:-/proc}
FULL_MEM_GB=${FULL_MEM_GB:-16} MIN_CPUS=${MIN_CPUS:-8} FULL_CPUS=${FULL_CPUS:-12}
fails=0
say() { printf '%-5s %-11s %s\n' "$1" "$2" "$3"; [ "$1" != FAIL ] || fails=$((fails + 1)); }
ver() { grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }   # first x.y[.z] on stdin
ver_ge() {  # ver_ge <a> <b>: a >= b
  local i x y a b
  IFS=. read -r -a a <<<"$1"; IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    x=${a[i]:-0} y=${b[i]:-0}
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}
gb() { echo $(( $1 / 1024 / 1024 )); }   # KiB -> GiB

# check_tool <name> <level if missing> <min version or ""> <level if older> <version command...>
check_tool() {
  local name=$1 missing=$2 min=$3 old=$4 v; shift 4
  command -v "$name" >/dev/null || { say "$missing" "$name" "missing"; return; }
  v=$("$@" 2>&1 | ver)
  if [ -n "$min" ] && ! ver_ge "${v:-0}" "$min"; then say "$old" "$name" "${v:-unknown} (need >= $min)"; return; fi
  say OK "$name" "${v:-?}"
}

# --- docker: daemon, memory, cpus, disk, inotify, load -------------------------------------------------------------
docker_ok=0 node=''
if ! command -v docker >/dev/null; then
  say FAIL docker "missing"
elif ! info=$(docker info --format '{{.ServerVersion}} {{.MemTotal}} {{.NCPU}} {{.DockerRootDir}}' 2>/dev/null); then
  say FAIL docker "daemon not reachable (start Docker)"
else
  docker_ok=1
  read -r dver mem cpus root <<<"$info"
  say OK docker "daemon $dver, $cpus CPUs"
  # rounded, not truncated: Docker Desktop set to 16 GB reports ~15.6 GiB (the VM kernel keeps some)
  memgb=$(( (mem + 512 * 1024 * 1024) / 1024 / 1024 / 1024 ))
  if [ "$memgb" -lt "$MIN_MEM_GB" ]; then say FAIL memory "$memgb GB available to Docker (need >= $MIN_MEM_GB for hub + 1 worker)"
  elif [ "$memgb" -lt "$FULL_MEM_GB" ]; then say WARN memory "$memgb GB available to Docker: hub + 1 worker; the full lab needs >= $FULL_MEM_GB"
  else say OK memory "$memgb GB available to Docker"; fi
  # CPU is what the full lab runs out of first: at 12 CPUs a burst (worker rebirth + promotion wave) drove the load to
  # ~80 and the hub's k3s restarted (#76). Warn only: fewer CPUs boot, just slower and with fewer clusters.
  if [ "$cpus" -lt "$MIN_CPUS" ]; then say WARN cpus "$cpus for Docker: hub + 1 worker wants >= $MIN_CPUS, the full lab >= $FULL_CPUS"
  elif [ "$cpus" -lt "$FULL_CPUS" ]; then say WARN cpus "$cpus for Docker: hub + 1 worker; the full lab wants >= $FULL_CPUS"
  else say OK cpus "$cpus for Docker (full lab: >= $FULL_CPUS)"; fi

  # every CAPD node shares the Docker VM's disk; measure it from inside a lab node when one exists
  node=$(docker ps -q --filter "label=io.x-k8s.kind.cluster=$HUB" --filter label=io.x-k8s.kind.role=control-plane 2>/dev/null | head -1)
  os=$(uname -s)
  if [ -n "$node" ]; then kb=$(docker exec "$node" df -Pk / 2>/dev/null | awk 'NR==2 {print $4}'); where="Docker VM"
  elif [ "$os" = Linux ]; then kb=$(df -Pk "$root" 2>/dev/null | awk 'NR==2 {print $4}'); where=$root
  else kb=; fi
  if [ -z "$kb" ]; then
    say WARN disk "can't measure free Docker disk without a lab node: check Docker Desktop's disk limit (need >= $MIN_DISK_GB GB free)"
  elif [ "$(gb "$kb")" -lt "$MIN_DISK_GB" ]; then
    say FAIL disk "$(gb "$kb") GB free in $where (need >= $MIN_DISK_GB; DiskPressure evicts lab-wide): docker system df / docker image prune -a"
  else
    say OK disk "$(gb "$kb") GB free in $where (need >= $MIN_DISK_GB)"
  fi

  # several CAPD clusters exhaust the default inotify limits (kubelet/containerd "too many open files")
  if [ "$os" = Linux ]; then
    w=$(cat "$PROC_ROOT/sys/fs/inotify/max_user_watches" 2>/dev/null); i=$(cat "$PROC_ROOT/sys/fs/inotify/max_user_instances" 2>/dev/null)
  elif [ -n "$node" ]; then
    w=$(docker exec "$node" cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null); i=$(docker exec "$node" cat /proc/sys/fs/inotify/max_user_instances 2>/dev/null)
  else w='' i=''; fi
  if [ -z "$w$i" ]; then :
  elif [ "${w:-0}" -lt 1048576 ] || [ "${i:-0}" -lt 8192 ]; then
    say WARN inotify "max_user_watches=$w max_user_instances=$i: sudo sysctl fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192"
  else
    say OK inotify "max_user_watches=$w max_user_instances=$i"
  fi

  # CPU saturation right now (1-min load of the Docker VM; /proc/loadavg isn't namespaced, so a lab node sees it).
  # Above 2x the CPUs the hub's etcd/apiserver answer in seconds, not milliseconds (#76).
  if [ -n "$node" ]; then load=$(docker exec "$node" cat /proc/loadavg 2>/dev/null | awk '{print $1}')
  elif [ "$os" = Linux ]; then load=$(awk '{print $1}' "$PROC_ROOT/loadavg" 2>/dev/null)
  else load=''; fi
  if [ -z "$load" ]; then :
  elif awk -v l="$load" -v c="$cpus" 'BEGIN { exit !(l > 2 * c) }'; then
    say WARN load "$load on $cpus CPUs: CPU-starved, the hub control plane may restart (#76); pause promotions / rebirths"
  else
    say OK load "$load on $cpus CPUs"
  fi
fi

# --- tools ---------------------------------------------------------------------------------------------------------
# k3d >= 5.5: first release with config k3d.io/v1alpha5 (bootstrap/k3d-bootstrap.yaml); helm >= 3.8: OCI charts;
# clusterctl should not be older than the core provider it moves (repos/platform-charts/capi-providers)
core=$(awk '/version:/ {print $2; exit}' repos/platform-charts/capi-providers/values.yaml | ver)
check_tool k3d        FAIL 5.5.0 FAIL k3d version
check_tool kubectl    FAIL ""    FAIL kubectl version --client
check_tool helm       FAIL 3.8.0 FAIL helm version --short
check_tool clusterctl FAIL "${core%.*}.0" WARN clusterctl version -o short
check_tool gh         WARN ""    WARN gh --version
check_tool jq         WARN ""    WARN jq --version
check_tool kargo      WARN ""    WARN kargo version --client
check_tool shellcheck WARN ""    WARN shellcheck --version
if ! command -v yq >/dev/null; then say WARN yq "missing (make lint / make test need mikefarah yq v4)"
elif ! yq --version 2>&1 | grep -q mikefarah; then say WARN yq "not mikefarah yq v4 (make lint / make test need it)"
else say OK yq "$(yq --version 2>&1 | ver)"; fi
if command -v gh >/dev/null && ! gh auth status >/dev/null 2>&1; then
  say WARN gh-auth "not logged in: make up can't create the Kargo deploy key (gh auth login)"
fi

# --- the lab -------------------------------------------------------------------------------------------------------
if [ "$docker_ok" = 1 ]; then
  say INFO stage "$(bootstrap/bootstrap.sh stage 2>&1)"
  port=$(docker port $HUB-lb 6443/tcp 2>/dev/null | head -1 | awk -F: '{print $NF}')
  if [ -z "$(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$HUB" 2>/dev/null)" ]; then
    say INFO hub "not running (make up)"
  elif [ -n "$port" ] && kubectl --context $HUB --request-timeout=10s --server "https://127.0.0.1:$port" get --raw /readyz >/dev/null 2>&1; then
    say OK hub "API ready on https://127.0.0.1:$port"
    say INFO lab-lock "$(hack/lab-lock.sh status 2>&1)"
  else
    say FAIL hub "containers exist but the API doesn't answer (docker ps --filter label=io.x-k8s.kind.cluster=$HUB)"
  fi
fi

echo
if [ "$fails" -gt 0 ]; then echo "doctor: $fails problem(s)"; exit 1; fi
echo "doctor: OK"
