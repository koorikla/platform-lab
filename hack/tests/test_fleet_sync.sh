#!/usr/bin/env bash
# fleet-sync (hub CronJob): script shipped in the openbao chart ConfigMap; shellcheck + DRY_RUN against stubbed kubectl/curl
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
assert_yq "$o" 'select(.kind=="CronJob") | .spec.schedule' '*/2 * * * *'
assert_yq "$o" 'select(.kind=="CronJob") | .spec.jobTemplate.spec.template.spec.serviceAccountName' openbao-fleet-sync
assert_yq "$o" 'select(.kind=="Role" and .metadata.namespace=="fleet") | .rules[] | select(.resources[0]=="clusters") | .verbs | join(",")' get,list
script=$tmp/fleet-sync.sh
yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-fleet-sync") | .data["fleet-sync.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "fleet-sync.sh missing from the ConfigMap"
if command -v shellcheck >/dev/null; then shellcheck -s bash "$script" || fail "shellcheck fleet-sync.sh"; fi

# stubs: two worker clusters (dev1 has a kubeconfig, dev9 is still being born), OpenBao already has k8s-dev1 and a stale k8s-old
bin=$tmp/bin; mkdir -p "$bin" "$tmp/sa"; echo fake-jwt > "$tmp/sa/token"
kc=$(printf 'apiVersion: v1\nkind: Config\nclusters:\n- name: dev1\n  cluster:\n    server: https://172.23.0.3:6443\n    certificate-authority-data: %s\ncontexts: []\nusers: []\n' "$(printf 'FAKE CA' | base64)")
cat > "$bin/kubectl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "get clusters.cluster.x-k8s.io"*) printf 'dev1\ndev9\n' ;;
  "get secret dev1-kubeconfig"*) printf '%s' "$(printf '%s' "$kc" | base64)" ;;
  "get secret"*) echo 'Error from server (NotFound)' >&2; exit 1 ;;
  config*) exec "$(command -v kubectl)" "\$@" ;;
  *) echo "unexpected kubectl \$*" >&2; exit 1 ;;
esac
STUB
cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
url=${*: -1}
[[ "$*" != *@-* ]] || cat >/dev/null   # like curl: drain the request body (else SIGPIPE under pipefail)
case "$url" in
  */v1/auth/kubernetes/login) echo '{"auth":{"client_token":"t"}}' ;;
  */v1/sys/auth) echo '{"data":{"token/":{},"kubernetes/":{},"k8s-dev1/":{},"k8s-old/":{}}}' ;;
  */v1/sys/policies/acl?list=true) echo '{"data":{"keys":["default","hub-writer","cluster-dev1","cluster-old"]}}' ;;
  *) echo "unexpected curl $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/kubectl" "$bin/curl"
out=$(PATH="$bin:$PATH" DRY_RUN=1 SA_DIR="$tmp/sa" bash "$script" 2>&1) || fail "fleet-sync DRY_RUN failed: $out"
grep -q 'DRY_RUN: POST /v1/auth/k8s-dev1/config .*"kubernetes_host":"https://172.23.0.3:6443".*"disable_local_ca_jwt":true' <<<"$out" || fail "no config write for k8s-dev1: $out"
grep -q 'DRY_RUN: POST /v1/sys/auth/k8s-dev1' <<<"$out" && fail "k8s-dev1 exists already, must not be re-enabled: $out"
grep -q 'DRY_RUN: POST /v1/auth/k8s-dev1/role/eso .*"bound_service_account_names":\["external-secrets"\].*"token_policies":\["cluster-dev1"\]' <<<"$out" || fail "no eso role for dev1: $out"
grep -q 'DRY_RUN: PUT /v1/sys/policies/acl/cluster-dev1 .*secret/data/clusters/dev1/\*' <<<"$out" || fail "no policy for dev1: $out"
grep -q '^ensured k8s-dev1' <<<"$out" || fail "no log line for dev1: $out"
grep -q '^skipped dev9' <<<"$out" || fail "dev9 (no kubeconfig yet) must be skipped: $out"
grep -q 'DRY_RUN: DELETE /v1/sys/auth/k8s-old' <<<"$out" || fail "stale mount k8s-old not removed: $out"
grep -q 'DRY_RUN: DELETE /v1/sys/policies/acl/cluster-old' <<<"$out" || fail "stale policy cluster-old not removed: $out"
grep -q 'DELETE /v1/sys/auth/k8s-dev9' <<<"$out" && fail "a cluster that is still being born must keep its mount: $out"
grep -q 'FAKE CA' <<<"$out" && fail "CA/JWT material must not be logged: $out"
true
