#!/usr/bin/env bash
# Fake docker/kubectl/k3d/helm/clusterctl/gh/... for test_boot.sh and test_doctor.sh (symlinked under each tool name).
# Behaviour comes from files in $FAKE_STATE, every call is appended to $FAKE_STATE/calls. Never reaches a real daemon,
# cluster or git remote. State files:
#   hub_up, hub_cluster, argo      hub API answers / has Cluster mgmt / helm release argocd deployed
#   boot, boot_up, boot_cluster    k3d "bootstrap" exists / answers / has Cluster mgmt
#   containers/<cluster>           docker containers labelled io.x-k8s.kind.cluster=<cluster> exist
#   capi/<cluster>                 worker Cluster object on the hub; `kubectl delete clusters` removes it and, unless
#                                  `stuck` exists, its containers (CAPD's job)
#   err_hub_cluster, err_boot_cluster, err_helm, err_kargo_secret: that read fails with a timeout (not NotFound)
#   kargo_ns, kargo_secret, gh_auth, docker_down, uname, df, inotify_*, <tool>_version: see the cases below
set -u
S=${FAKE_STATE:?}
cmd=$(basename "$0")
echo "$cmd $*" >> "$S/calls"
has() { [ -e "$S/$1" ]; }
out() { if has "$1"; then cat "$S/$1"; else printf '%s\n' "$2"; fi; }   # out <state-file> <default>
a=" $* "
nf()      { echo "Error from server (NotFound): $1 not found" >&2; exit 1; }
apierr() { echo "Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded)" >&2; exit 1; }

# the word after <word> in the arguments
after() { local w=$1 prev=; shift; for x in "$@"; do [ "$prev" = "$w" ] && { echo "$x"; return; }; prev=$x; done; }

case $cmd in
kubectl)
  case $a in
    *" version --client "*) out kubectl_version "Client Version: v1.37.0"; exit 0 ;;
    " config "*) exit 0 ;;
    *" --context mgmt "*) has hub_up || apierr; side=hub ;;
    *" --context k3d-bootstrap "*) has boot_up || apierr; side=boot ;;
    *) exit 1 ;;
  esac
  case $a in
    *" get --raw /readyz "*) echo ok ;;
    *" get clusters.cluster.x-k8s.io mgmt "*) ! has "err_${side}_cluster" || apierr; has "${side}_cluster" || nf mgmt ;;
    *" get secret -l owner=helm,name=argocd,status=deployed "*)
      ! has err_helm || apierr; ! has argo || echo secret/sh.helm.release.v1.argocd.v1 ;;
    *" get crd clusters.cluster.x-k8s.io "*) has hub_cluster || nf clusters.cluster.x-k8s.io ;;
    *" get clusters.cluster.x-k8s.io -l platform.lab/role=worker "*) ls "$S/capi" 2>/dev/null | tr '\n' ' ' ;;
    *" get clusters.cluster.x-k8s.io "*) w=$(after clusters.cluster.x-k8s.io "$@"); has "capi/$w" || nf "$w" ;;
    *" delete clusters.cluster.x-k8s.io "*)
      for f in "$S"/capi/*; do
        [ -e "$f" ] || continue
        rm "$f"; has stuck || rm -f "$S/containers/$(basename "$f")"
      done ;;
    *" scale "*) ;;
    *" get namespace kargo-shared-resources "*) has kargo_ns ;;
    *" get secret git-platform-lab "*) ! has err_kargo_secret || apierr; has kargo_secret || nf secret ;;
    *" apply -f bootstrap/root-app.yaml "*) touch "$S/root_app" ;;
    *" get lease "*) exit 1 ;;
    *) echo "fake kubectl: unhandled: $*" >&2; exit 1 ;;
  esac ;;
docker)
  case $a in
    " --version ") echo "Docker version 28.1.1, build 4eba377" ;;
    " info "*) has docker_down && exit 1; out docker_info "28.1.1 17179869184 12 /var/lib/docker" ;;
    " network "*) ;;
    " port mgmt-lb 6443/tcp ") has containers/mgmt && echo 0.0.0.0:55000 ;;
    " ps "*"label=io.x-k8s.kind.cluster="*)
      c=${a##*label=io.x-k8s.kind.cluster=}; c=${c%% *}
      ! has "containers/$c" || echo "$c-id" ;;
    " rm "*) for id in "$@"; do case $id in *-id) rm -f "$S/containers/${id%-id}" ;; esac; done ;;
    " exec "*" df "*) out df "$(printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 131787236 85747372 39312648 69%% /')" ;;
    " exec "*"max_user_watches "*) out inotify_watches 1048576 ;;
    " exec "*"max_user_instances "*) out inotify_instances 8192 ;;
    *) echo "fake docker: unhandled: $*" >&2; exit 1 ;;
  esac ;;
k3d)
  case $a in
    " cluster list bootstrap ") has boot ;;
    " cluster start bootstrap ") touch "$S/boot_up" ;;
    " cluster delete bootstrap ") rm -f "$S/boot" "$S/boot_up" "$S/boot_cluster" ;;
    " version ") out k3d_version "k3d version v5.9.0"; echo "k3s version v1.35.5-k3s1 (default)" ;;
    *) echo "fake k3d: unhandled: $*" >&2; exit 1 ;;
  esac ;;
helm)  # dependency build / upgrade succeed so a wrong decision shows up as a logged `helm upgrade`
  case $a in
    " version --short ") out helm_version "v4.3.0+gbec5b06" ;;
    " dependency build "*|" upgrade "*) ;;
    *) exit 1 ;;
  esac ;;
clusterctl) [ "$a" = " version -o short " ] && out clusterctl_version "v1.14.2" ;;
gh)
  case $a in
    " auth status ") has gh_auth ;;
    " --version ") echo "gh version 2.100.0 (2026-09-03)" ;;
    *) exit 1 ;;
  esac ;;
yq)         out yq_version "yq (https://github.com/mikefarah/yq/) version v4.53.6" ;;
jq)         echo "jq-1.8.2" ;;
kargo)      echo "Client Version: 1.11.4" ;;
shellcheck) printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n' ;;
uname)      out uname Darwin ;;
df)         out hostdf "$(printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 131787236 85747372 39312648 69%% /')" ;;
init-rendered-branches.sh|kargo-deploy-key.sh) touch "$S/ran_$cmd" ;;
git|ssh)    echo "fake $cmd: tests never talk to a git remote" >&2; exit 1 ;;
*) echo "fakebin: no fake for $cmd" >&2; exit 1 ;;
esac
