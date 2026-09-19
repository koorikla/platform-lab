# shellcheck shell=bash disable=SC2154  # $tmp comes from lib.sh
# hack/tests/fakes.sh — sourced after lib.sh by tests that run bootstrap.sh / doctor.sh against fake tools.
# new_fakes: fresh state dir ($FAKE_STATE) whose bin/ fakes every lab tool with hack/tests/fakebin.sh.
# fenv <cmd...>: run with only those fakes + base system dirs on PATH and an empty HOME/KUBECONFIG, so a missing fake
# fails loudly instead of reaching the real docker daemon, lab kube contexts or git remote.
fake_tools="docker kubectl k3d helm clusterctl gh yq jq kargo shellcheck uname df init-rendered-branches.sh kargo-deploy-key.sh"
new_fakes() {
  local t
  FAKE_STATE=$(mktemp -d "$tmp/state.XXXXXX"); export FAKE_STATE
  mkdir -p "$FAKE_STATE/bin" "$FAKE_STATE/containers" "$FAKE_STATE/capi" "$FAKE_STATE/home"
  for t in $fake_tools; do ln -s "$PWD/hack/tests/fakebin.sh" "$FAKE_STATE/bin/$t"; done
}
fenv() {
  env PATH="$FAKE_STATE/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$FAKE_STATE/home" \
    KUBECONFIG="$FAKE_STATE/home/kubeconfig" POLL=0 "$@"
}
# state <file...>: create state files (see fakebin.sh), e.g. `state hub_up containers/mgmt`
state() { local f; for f in "$@"; do touch "$FAKE_STATE/$f"; done; }
calls() { cat "$FAKE_STATE/calls" 2>/dev/null || true; }
# line number of the first call matching an ERE (0 if none) — for ordering assertions
call_at() { local n; n=$(calls | grep -nE -m1 -- "$1" | cut -d: -f1); echo "${n:-0}"; }
