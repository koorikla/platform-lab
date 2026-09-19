#!/usr/bin/env bash
# hack/doctor.sh against fake tools (hack/tests/fakebin.sh): FAIL (exit 1) on what breaks a boot — docker down, <25 GB
# free Docker disk, too little memory, a missing/too old required tool — and WARN on the rest.
source "$(dirname "$0")/lib.sh"
source hack/tests/fakes.sh

doctor() {  # -> output in $FAKE_STATE/out, exit code in $rc
  rc=0; fenv hack/doctor.sh > "$FAKE_STATE/out" 2>&1 || rc=$?
}
has() { grep -qE -- "$1" "$FAKE_STATE/out" || fail "line ${BASH_LINENO[0]}: no line matching '$1' in:
$(cat "$FAKE_STATE/out")"; }
rc_is() { [ "$rc" = "$1" ] || fail "line ${BASH_LINENO[0]}: exit $rc, want $1:
$(cat "$FAKE_STATE/out")"; }

# healthy macOS host with a running lab: everything OK, disk measured inside a lab node, lock status shown
new_fakes; state containers/mgmt hub_up hub_cluster argo gh_auth
doctor; rc_is 0
has '^OK +docker'
has '^OK +disk .*37 GB free'
has '^OK +memory .*16 GB'
for t in k3d kubectl helm clusterctl; do has "^OK +$t "; done
has '^OK +hub '
has '^INFO +stage +argo'
has '^INFO +lab-lock +free'
! grep -q '^FAIL' "$FAKE_STATE/out" || fail "unexpected FAIL: $(cat "$FAKE_STATE/out")"

# too little free disk in the Docker VM
new_fakes; state containers/mgmt
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\noverlay 131787236 120000000 10485760 92%% /\n' > "$FAKE_STATE/df"
doctor; rc_is 1; has '^FAIL +disk .*10 GB free'

# too little memory for hub + a worker
new_fakes; echo "28.1.1 4294967296 4 /var/lib/docker" > "$FAKE_STATE/docker_info"
doctor; rc_is 1; has '^FAIL +memory'

# Docker Desktop minimums for the full lab (hub + dev1 + dev2 + OpenChoreo, #76): 12 CPUs / 16 GB; below = WARN only.
# Docker Desktop's "16 GB" shows ~15.6 GiB (the real VM of #76): counts as 16, no warning
new_fakes; echo "28.1.1 16745562112 12 /var/lib/docker" > "$FAKE_STATE/docker_info"
doctor; rc_is 0; has '^OK +memory .*16 GB'; has '^OK +cpus +12 '
# 8 GB + 8 CPUs: enough for hub + 1 worker, not the full lab
new_fakes; echo "28.1.1 8321499136 8 /var/lib/docker" > "$FAKE_STATE/docker_info"
doctor; rc_is 0; has '^WARN +memory .*8 GB.*full lab.*>= 16'; has '^WARN +cpus +8 .*full lab.*>= 12'
# 4 CPUs: below even hub + 1 worker (still a warning: it boots, slowly)
new_fakes; echo "28.1.1 17179869184 4 /var/lib/docker" > "$FAKE_STATE/docker_info"
doctor; rc_is 0; has '^WARN +cpus +4 .*hub \+ 1 worker.*>= 8'

# CPU saturation of the Docker VM, measured in a lab node: load above 2x CPUs = the hub control plane starves (#76)
new_fakes; state containers/mgmt hub_up
echo "80.12 75.40 60.00 110/2734 125935" > "$FAKE_STATE/loadavg"
doctor; rc_is 0; has '^WARN +load +80\.12 .*12 CPUs'
new_fakes; state containers/mgmt hub_up
doctor; rc_is 0; has '^OK +load +3\.10 '

# docker daemon down: fail fast, no lab checks
new_fakes; state docker_down
doctor; rc_is 1; has '^FAIL +docker'

# required tool missing / too old; optional tool missing is only a warning
new_fakes; rm "$FAKE_STATE/bin/k3d" "$FAKE_STATE/bin/kargo"
doctor; rc_is 1; has '^FAIL +k3d +missing'; has '^WARN +kargo +missing'
new_fakes; echo "k3d version v5.4.9" > "$FAKE_STATE/k3d_version"
doctor; rc_is 1; has '^FAIL +k3d .*5\.4\.9.*need >= 5\.5\.0'
new_fakes; echo "yq 3.4.1" > "$FAKE_STATE/yq_version"
doctor; rc_is 0; has '^WARN +yq .*mikefarah'

# no lab yet on macOS: disk can't be measured without a lab node -> warn, not fail; no hub is fine before `make up`
new_fakes
doctor; rc_is 0; has '^WARN +disk'; has '^INFO +hub +not running'; has '^INFO +stage +fresh'

# Linux: disk from the host's Docker root dir; inotify limits below what several CAPD clusters need -> hint
new_fakes; echo Linux > "$FAKE_STATE/uname"
mkdir -p "$FAKE_STATE/proc/sys/fs/inotify"
echo 8192 > "$FAKE_STATE/proc/sys/fs/inotify/max_user_watches"; echo 128 > "$FAKE_STATE/proc/sys/fs/inotify/max_user_instances"
rc=0; fenv PROC_ROOT="$FAKE_STATE/proc" hack/doctor.sh > "$FAKE_STATE/out" 2>&1 || rc=$?
rc_is 0; has '^OK +disk .*37 GB free'; has '^WARN +inotify .*sysctl fs.inotify.max_user_watches=1048576'
