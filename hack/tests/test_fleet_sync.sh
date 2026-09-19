#!/usr/bin/env bash
# fleet-sync (hub CronJob): RBAC without fleet secrets, script shipped in the openbao chart ConfigMap; shellcheck, then
# runs against stubbed kubectl/curl: DRY_RUN, one failing cluster, empty cluster list; every API path it calls must be
# covered by the fleet-sync policy that server.postStart writes.
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
cj='select(.kind=="CronJob" and .metadata.name=="openbao-fleet-sync")'
assert_yq "$o" "$cj | .spec.schedule" '*/2 * * * *'
assert_yq "$o" "$cj | .spec.jobTemplate.spec.template.spec.serviceAccountName" openbao-fleet-sync
assert_yq "$o" "$cj | .spec.jobTemplate.spec.template.spec.containers[0].image | test(\"^alpine/k8s:[0-9.]+@sha256:[0-9a-f]{64}\$\")" true
# fleet namespace: CAPI Clusters only (kubeconfigs and CA keys live there); secrets only in openbao (<name>-ca-public)
assert_yq "$o" '[select(.kind=="Role" and .metadata.namespace=="fleet") | .rules[] | .resources[]] | join(",")' clusters
assert_yq "$o" 'select(.kind=="Role" and .metadata.namespace=="openbao" and .metadata.name=="openbao-fleet-sync") | .rules[] | .resources[0] + ":" + (.verbs | join(","))' secrets:get
assert_yq "$o" 'select(.kind=="SecretStore" and .metadata.name=="fleet-ca") | .spec.provider.kubernetes.auth.serviceAccount.name' fleet-ca-projector

script=$tmp/fleet-sync.sh
yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-fleet-sync") | .data["fleet-sync.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "fleet-sync.sh missing from the ConfigMap"
if command -v shellcheck >/dev/null; then shellcheck -s bash "$script" || fail "shellcheck fleet-sync.sh"; fi
policy=$(yq 'select(.kind=="StatefulSet") | .spec.template.spec.containers[0].lifecycle.postStart.exec.command[2]' "$o" |
  awk '/policy write fleet-sync/ {f=1; next} /^EOP/ {f=0} f')
grep -q '^path "auth/k8s-\*"' <<<"$policy" || fail "fleet-sync policy not found in postStart"

# stubs. OpenBao has k8s-dev1 and a stale k8s-old. $tmp/clusters = kubectl's "<name> <host> <port>" lines.
bin=$tmp/bin; mkdir -p "$bin" "$tmp/sa"; printf 'fake-jwt' > "$tmp/sa/token"
cat > "$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "get clusters.cluster.x-k8s.io"*) cat "$STUB_DIR/clusters" ;;
  "get secret dev1-ca-public -n openbao"*|"get secret dev6-ca-public -n openbao"*|"get secret dev8-ca-public -n openbao"*)
    printf 'FAKE CA' | base64 ;;
  "get secret"*) echo 'Error from server (NotFound)' >&2; exit 1 ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
STUB
cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
url=${*: -1}; path=${url#*/v1/}; method=GET
args=("$@"); for i in "${!args[@]}"; do [ "${args[$i]}" != -X ] || method=${args[$((i + 1))]}; done
echo "$*" >> "$STUB_DIR/argv"
[[ "$*" != *@-* ]] || cat >/dev/null   # like curl: drain the request body (else SIGPIPE under pipefail)
echo "$method $path" >> "$STUB_DIR/calls"
case "$method $path" in
  "POST auth/kubernetes/login") echo '{"auth":{"client_token":"s.faketoken"}}' ;;
  "GET sys/auth") echo '{"data":{"token/":{},"kubernetes/":{},"k8s-dev1/":{},"k8s-old/":{}}}' ;;
  "GET sys/policies/acl?list=true") echo '{"data":{"keys":["default","hub-writer","cluster-dev1","cluster-old"]}}' ;;
  "POST auth/k8s-dev8/config") echo '{"errors":["permission denied"]}'; exit 22 ;;
  "GET "*) echo "unexpected GET $path" >&2; exit 1 ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$bin/kubectl" "$bin/curl"
run() {  # run <clusters> [env...] -> output in $out, status in $st, calls in $tmp/calls
  printf '%b' "$1" > "$tmp/clusters"; : > "$tmp/calls"; : > "$tmp/argv"; shift
  set +e; out=$(env PATH="$bin:$PATH" STUB_DIR="$tmp" SA_DIR="$tmp/sa" "$@" bash "$script" 2>&1); st=$?; set -e
}
has() { grep -q -- "$1" <<<"$out" || fail "${2:-expected '$1'}: $out"; }
hasnt() { ! grep -q -- "$1" <<<"$out" || fail "${2:-unexpected '$1'}: $out"; }

# 1. DRY_RUN: dev1 ready, dev9 without endpoint, dev7 without projected CA
run 'dev1 172.23.0.3 6443\ndev9  \ndev7 172.23.0.9 6443\n' DRY_RUN=1
[ "$st" = 0 ] || fail "DRY_RUN exit $st: $out"
has 'DRY_RUN: POST /v1/auth/k8s-dev1/config .*"kubernetes_host":"https://172.23.0.3:6443".*"disable_local_ca_jwt":true'
hasnt 'DRY_RUN: POST /v1/sys/auth/k8s-dev1' "k8s-dev1 exists already, must not be re-enabled"
has 'DRY_RUN: POST /v1/auth/k8s-dev1/role/eso .*"bound_service_account_names":"external-secrets".*"token_policies":"cluster-dev1"'
has 'DRY_RUN: PUT /v1/sys/policies/acl/cluster-dev1 .*secret/data/clusters/dev1/\*'
has '^ensured k8s-dev1'
has '^skipped dev9: no controlPlaneEndpoint' && has '^skipped dev7: no openbao/dev7-ca-public'
has 'DRY_RUN: DELETE /v1/sys/auth/k8s-old' && has 'DRY_RUN: DELETE /v1/sys/policies/acl/cluster-old'
hasnt 'DELETE /v1/sys/auth/k8s-dev[79]' "clusters being born must keep their mounts"
hasnt 'FAKE CA' "CA must not be logged"

# 2. real mode: dev6 new, dev8 fails -> the others still converge, cleanup still runs, exit 1, token only via header file
run 'dev1 172.23.0.3 6443\ndev8 172.23.0.8 6443\ndev6 172.23.0.6 6443\n'
[ "$st" = 1 ] || fail "one failing cluster must exit 1, got $st: $out"
has '^failed dev8' && has '^ensured k8s-dev1' && has '^ensured k8s-dev6' && has '^removed k8s-old' && has '^removed policy cluster-old'
grep -qx 'POST sys/auth/k8s-dev6' "$tmp/calls" || fail "new cluster dev6: mount not enabled"
grep -qx 'POST auth/token/revoke-self' "$tmp/calls" || fail "token not revoked at exit"
! grep -q 's.faketoken\|fake-jwt' "$tmp/argv" || fail "token/JWT on curl's argv"
grep -q -- '-H @' "$tmp/argv" || fail "token header not passed as a file"
# every path the script touches (bar login/revoke-self) is granted by the fleet-sync policy
patterns=$(sed -n 's/^path "\([^"]*\)".*/\1/p' <<<"$policy")
while read -r method path; do
  path=${path%%\?*}
  case "$path" in auth/kubernetes/login|auth/token/revoke-self) continue ;; esac
  ok=0; for p in $patterns; do [[ "$path" == ${p//+/[!\/]*} ]] && ok=1; done   # vault: trailing * = prefix, + = segment
  [ "$ok" = 1 ] || fail "fleet-sync policy doesn't cover $method $path (policy paths: $(tr '\n' ' ' <<<"$patterns"))"
done < "$tmp/calls"

# 3. empty cluster list while k8s-* mounts exist: log and leave OpenBao alone
run ''
[ "$st" = 0 ] || fail "empty list exit $st: $out"
has '^refusing cleanup: no worker clusters listed but 2 k8s-\* mounts exist'
! grep -q '^DELETE' "$tmp/calls" || fail "empty list must not delete anything: $(cat "$tmp/calls")"
true
