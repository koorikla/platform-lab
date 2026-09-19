#!/usr/bin/env bash
# bootstrap.sh against fake docker/kubectl/k3d (hack/tests/fakebin.sh): `make up` resumes from the stage the real state
# is in, `make down` deletes workers through CAPI and waits for their containers before removing the hub, and touches
# nothing that isn't the lab's.
source "$(dirname "$0")/lib.sh"
source hack/tests/fakes.sh
all="bootstrap-cluster bootstrap-capi hub-capi pivot drop-bootstrap argo root-app post"

# stage_is "<state files>" "<expected stage: steps>"
stage_is() {
  local got
  new_fakes; [ -z "$1" ] || state $1   # word-split on purpose: a list of state files
  got=$(fenv bootstrap/bootstrap.sh stage) || fail "line ${BASH_LINENO[0]}: bootstrap.sh stage failed: $got"
  [ "$got" = "$2" ] || fail "line ${BASH_LINENO[0]}: state [$1]: got '$got', want '$2'"
  # detection is read-only: no create/apply/delete/start/scale/rm/move/helm install, no kubeconfig edits
  ! calls | grep -E ' (create|apply|delete|start|scale|rm|move|upgrade|install|config)( |$)' ||
    fail "line ${BASH_LINENO[0]}: stage detection mutated something"
}

stage_is ""                                                        "fresh: $all"
stage_is "boot boot_up"                                            "bootstrap: $all"
# a stopped k3d hides what it holds (maybe a half-moved hub): start it, then detect again
stage_is "boot"                                                    "bootstrap-stopped: start-bootstrap"
stage_is "boot containers/mgmt hub_up hub_cluster"                 "bootstrap-stopped: start-bootstrap"
stage_is "boot boot_up boot_cluster"                               "hub-requested: hub-capi pivot drop-bootstrap argo root-app post"
stage_is "boot boot_up boot_cluster containers/mgmt"               "hub-requested: hub-capi pivot drop-bootstrap argo root-app post"
stage_is "boot boot_up boot_cluster containers/mgmt hub_up"        "hub-requested: hub-capi pivot drop-bootstrap argo root-app post"
# clusterctl move was interrupted: objects on both sides; move is safe to re-run (it updates what already exists)
stage_is "boot boot_up boot_cluster containers/mgmt hub_up hub_cluster" "pivot-partial: pivot drop-bootstrap argo root-app post"
stage_is "boot boot_up containers/mgmt hub_up hub_cluster"         "pivoted: drop-bootstrap argo root-app post"
stage_is "containers/mgmt hub_up hub_cluster"                      "pivoted: argo root-app post"
stage_is "containers/mgmt hub_up hub_cluster argo"                 "argo: root-app post"
stage_is "boot boot_up containers/mgmt hub_up hub_cluster argo"    "argo: drop-bootstrap root-app post"
# hub containers but no way to reach or rebuild them: never create a second hub next to them
stage_is "containers/mgmt"                                         "orphan: -"
stage_is "containers/mgmt hub_up"                                  "orphan: -"
stage_is "boot boot_up containers/mgmt hub_up"                     "orphan: -"

# up refuses to build a second hub next to orphaned hub containers, and doesn't send people to `make down` first
# (after a Docker restart the hub API just needs a moment)
new_fakes; state containers/mgmt
fenv bootstrap/bootstrap.sh up > "$FAKE_STATE/out" 2>&1 && fail "up accepted orphaned hub containers"
! calls | grep -qE '^k3d cluster create' || fail "up created a bootstrap cluster next to an orphaned hub"
grep -q 'Docker just restarted, wait' "$FAKE_STATE/out" || fail "orphan message: $(cat "$FAKE_STATE/out")"

# a read that errors (timeout, 5xx) is not "absent": abort instead of re-installing Argo CD, moving, deleting the
# bootstrap cluster or rotating the Kargo deploy key
up_errs() {  # state files...
  new_fakes; state "$@"
  assert_fails fenv bootstrap/bootstrap.sh up
  ! calls | grep -qE '^(helm |clusterctl move|k3d cluster (create|delete))' ||
    fail "line ${BASH_LINENO[0]}: acted on a failed read: $(calls | grep -E '^(helm|clusterctl|k3d)')"
  [ ! -e "$FAKE_STATE/ran_kargo-deploy-key.sh" ] || fail "line ${BASH_LINENO[0]}: deploy key rotated on a failed read"
}
up_errs containers/mgmt hub_up hub_cluster argo err_helm
up_errs boot boot_up boot_cluster containers/mgmt hub_up hub_cluster err_boot_cluster
up_errs boot boot_up containers/mgmt hub_up hub_cluster err_hub_cluster
up_errs containers/mgmt hub_up hub_cluster argo kargo_ns gh_auth err_kargo_secret
new_fakes; state boot boot_up containers/mgmt hub_up hub_cluster err_boot_cluster
assert_fails fenv bootstrap/bootstrap.sh stage

# up on an installed hub: no helm/clusterctl, root app ensured, rendered branches initialised, deploy key only when the
# Kargo secret is missing (never rotated on a re-run) and gh is authenticated
up_argo() {  # extra state files...
  new_fakes; state containers/mgmt hub_up hub_cluster argo kargo_ns "$@"
  fenv KARGO_WAIT=0 bootstrap/bootstrap.sh up > "$FAKE_STATE/out" 2>&1 || { cat "$FAKE_STATE/out" >&2; fail "line ${BASH_LINENO[0]}: up failed"; }
  ! calls | grep -qE '^(helm (upgrade|install)|clusterctl move|k3d cluster create)' || fail "up redid finished stages"
  [ -e "$FAKE_STATE/root_app" ] || fail "root app not applied"
  [ -e "$FAKE_STATE/ran_init-rendered-branches.sh" ] || fail "rendered branches not initialised"
}
up_argo gh_auth
[ -e "$FAKE_STATE/ran_kargo-deploy-key.sh" ] || fail "deploy key not created although the Kargo secret is missing"
up_argo gh_auth kargo_secret
[ ! -e "$FAKE_STATE/ran_kargo-deploy-key.sh" ] || fail "deploy key rotated although the Kargo secret exists"
up_argo
[ ! -e "$FAKE_STATE/ran_kargo-deploy-key.sh" ] || fail "deploy key attempted without gh auth"
grep -q 'kargo-deploy-key.sh' "$FAKE_STATE/out" || fail "no hint to run kargo-deploy-key.sh when gh is not authenticated"

# --- make down ---------------------------------------------------------------------------------------------------
# full lab: Argo stopped first (else it recreates the Clusters), workers via CAPI and gone before the hub goes,
# hub containers by CAPD label, mgmt context removed; an unrelated kind cluster survives
new_fakes; state containers/mgmt hub_up hub_cluster argo capi/dev1 containers/dev1 capi/dev2 containers/dev2 containers/my-cluster
fenv bootstrap/bootstrap.sh down > "$FAKE_STATE/out" 2>&1 || { cat "$FAKE_STATE/out" >&2; fail "down failed"; }
for c in mgmt dev1 dev2; do [ ! -e "$FAKE_STATE/containers/$c" ] || fail "containers of $c left behind"; done
[ -e "$FAKE_STATE/containers/my-cluster" ] || fail "down removed an unrelated cluster's containers"
scale=$(call_at '^kubectl .*-n argocd scale ')
del=$(call_at '^kubectl .*delete clusters.cluster.x-k8s.io -l platform.lab/role=worker')
hub=$(call_at '^docker rm .*mgmt-id')
[ "$scale" -gt 0 ] && [ "$scale" -lt "$del" ] && [ "$del" -lt "$hub" ] ||
  fail "down order: argo scale ($scale) < delete workers ($del) < remove hub ($hub)"
! calls | grep -qE '^kind |delete clusters.cluster.x-k8s.io mgmt|docker rm .*my-cluster' || fail "down touched what it must not"
calls | grep -q '^kubectl config delete-context mgmt' || fail "mgmt context not removed"
! calls | grep -q '^k3d cluster delete' || fail "k3d delete without a bootstrap cluster"

# workers stuck in CAPI deletion: time out and keep the hub (removing it would leak the workers' containers)
new_fakes; state containers/mgmt hub_up hub_cluster capi/dev1 containers/dev1 stuck
assert_fails fenv DOWN_TIMEOUT=0 bootstrap/bootstrap.sh down
[ -e "$FAKE_STATE/containers/mgmt" ] || fail "hub removed while workers still exist"

# hub unreachable, worker containers left: refuse (they can't go through CAPI) unless FORCE=1, and keep the hub
new_fakes; state containers/mgmt containers/dev1 containers/my-cluster
assert_fails fenv bootstrap/bootstrap.sh down
[ -e "$FAKE_STATE/containers/dev1" ] && [ -e "$FAKE_STATE/containers/mgmt" ] || fail "down without FORCE removed containers"
fenv FORCE=1 bootstrap/bootstrap.sh down >/dev/null 2>&1 || fail "FORCE=1 down failed"
[ ! -e "$FAKE_STATE/containers/dev1" ] && [ ! -e "$FAKE_STATE/containers/mgmt" ] || fail "FORCE=1 down left lab containers"
[ -e "$FAKE_STATE/containers/my-cluster" ] || fail "FORCE=1 down removed an unrelated cluster's containers"

# not pivoted yet: the bootstrap cluster's CAPD owns the hub, so it goes first (else it recreates the hub's machines)
new_fakes; state boot boot_up boot_cluster containers/mgmt
fenv bootstrap/bootstrap.sh down >/dev/null 2>&1 || fail "down (unpivoted) failed"
k3d=$(call_at '^k3d cluster delete bootstrap'); hub=$(call_at '^docker rm .*mgmt-id')
[ "$k3d" -gt 0 ] && [ "$k3d" -lt "$hub" ] || fail "down order: k3d bootstrap ($k3d) before hub containers ($hub)"

# nothing there: down is a no-op that succeeds (safe to re-run)
new_fakes
fenv bootstrap/bootstrap.sh down >/dev/null 2>&1 || fail "down on an empty machine failed"

# a stopped bootstrap is started, then the stage is detected again (here: it held the hub request)
new_fakes; state boot boot_cluster
fenv HUB_TIMEOUT=0 bootstrap/bootstrap.sh up >/dev/null 2>&1 || true   # fails at hub-capi: no machines in a fake
calls | grep -q '^k3d cluster start bootstrap' || fail "stopped bootstrap not started"
! calls | grep -qE '^k3d cluster create|^helm ' || fail "restarted bootstrap re-ran the bootstrap steps"
