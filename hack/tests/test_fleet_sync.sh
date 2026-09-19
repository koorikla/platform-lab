#!/usr/bin/env bash
# fleet-sync (hub CronJob): script shipped in the openbao chart ConfigMap; shellcheck, then runs against stubbed
# kubectl/curl: DRY_RUN, one failing cluster, empty cluster list. #30: fleet-sync writes no policy at all - every
# worker's ESO gets the one fixed, templated policy cluster-reader, and fleet-sync binds the login to entity
# cluster-<name> (metadata cluster=<name>) instead. Every API path and parameter it sends must be granted by the
# fleet-sync policy (ConfigMap openbao-configure, applied by the configure sidecar). CronJob, image and its own RBAC:
# openbao chart unit tests (tests/fleet_sync_test.yaml); the per-worker grant: cluster chart (tests/openbao_ca_test.yaml).
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
cj='select(.kind=="CronJob" and .metadata.name=="openbao-fleet-sync")'
fs_sa=$(yq "$cj | .spec.jobTemplate.spec.template.spec.serviceAccountName" "$o")
# no Secret in openbao by chart: that namespace holds openbao-unseal-key and the openchoreo-* sources. The cluster chart
# grants `get` on exactly <name>-ca-public per worker, bound to this SA; the list of clusters comes from CAPI Clusters,
# never from listing Secrets.
sa_bindings="[select(.kind==\"RoleBinding\" or .kind==\"ClusterRoleBinding\") | select(.subjects | any_c(.name==\"$fs_sa\"))]"
assert_yq "$o" "$sa_bindings | map(.metadata.namespace) | join(\",\")" fleet
w=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$w" "[select(.kind==\"RoleBinding\") | select(.subjects | any_c(.name==\"$fs_sa\")) | .metadata.namespace + \"/\" + .roleRef.name] | join(\",\")" \
  "$(yq "$cj | .metadata.namespace" "$o")/fleet-sync-dev1"
! grep -qE 'kubectl (get|list) secrets?( |$).*(-l|--selector|-A|--all)' <<<"$(yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-fleet-sync") | .data["fleet-sync.sh"]' "$o")" ||
  fail "fleet-sync must get Secrets by name only"

script=$tmp/fleet-sync.sh
yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-fleet-sync") | .data["fleet-sync.sh"]' "$o" > "$script"
[ -s "$script" ] || fail "fleet-sync.sh missing from the ConfigMap"
if command -v shellcheck >/dev/null; then shellcheck -s bash "$script" || fail "shellcheck fleet-sync.sh"; fi
conf='select(.kind=="ConfigMap" and .metadata.name=="openbao-configure") | .data'
policy=$(yq "$conf | .[\"fleet-sync.hcl\"]" "$o")
grep -q '^path "auth/k8s-\*"' <<<"$policy" || fail "fleet-sync policy not found in ConfigMap openbao-configure"
# the residual risk of the dev-mode design is gone: no policy writes, and the only policy a worker role may carry is
# cluster-reader, whose single path is templated on the entity (OpenBao blocks / * + in substituted values)
! grep -q 'sys/policies' <<<"$policy" || fail "fleet-sync must not be able to write policies: $policy"
reader=$(yq "$conf | .[\"cluster-reader.hcl\"]" "$o" | grep -vE '^ *(#|$)')
[ "$reader" = 'path "secret/data/clusters/{{identity.entity.metadata.cluster}}/*" { capabilities = ["read"] }' ] ||
  fail "cluster-reader must be exactly one read-only templated path: $reader"
grep -qF '"token_policies" = ["cluster-reader"]' <<<"$policy" || fail "fleet-sync may bind only cluster-reader: $policy"

# stubs. OpenBao has k8s-dev1 (+ entity cluster-dev1) and a stale k8s-old (+ entity cluster-old).
# $tmp/clusters = kubectl's "<name> <host> <port>" lines; $tmp/mounts = "<mount> <accessor>"; $tmp/entities = names.
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
url=${*: -1}; path=${url#*/v1/}; method=GET; body=
args=("$@")
for i in "${!args[@]}"; do
  [ "${args[$i]}" != -X ] || method=${args[$((i + 1))]}
  [ "${args[$i]}" != --data ] || body=${args[$((i + 1))]}
done
echo "$*" >> "$STUB_DIR/argv"
[[ "$*" != *@-* ]] || cat >/dev/null   # like curl: drain the request body (else SIGPIPE under pipefail)
echo "$method $path" >> "$STUB_DIR/calls"
[ -z "$body" ] || printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/bodies"
S=$STUB_DIR
case "$method $path" in
  "POST auth/kubernetes/login") echo '{"auth":{"client_token":"s.faketoken"}}' ;;
  "GET sys/auth")
    jq -Rn '{data: ([inputs | split(" ") | {key: (.[0] + "/"), value: {type: "kubernetes", accessor: .[1]}}] | from_entries
      | . + {"token/": {type: "token", accessor: "auth_token_1"}, "kubernetes/": {type: "kubernetes", accessor: "auth_kubernetes_hub"}})}' < "$S/mounts" ;;
  "POST sys/auth/"*) echo "${path#sys/auth/} auth_kubernetes_${path#sys/auth/k8s-}" >> "$S/mounts"; echo '{}' ;;
  "DELETE sys/auth/"*) grep -v "^${path#sys/auth/} " "$S/mounts" > "$S/m" || true; mv "$S/m" "$S/mounts"; echo '{}' ;;
  "POST auth/k8s-dev8/config") echo '{"errors":["permission denied"]}'; exit 22 ;;
  "POST identity/entity/name/"*)
    n=${path#identity/entity/name/}
    if grep -qx "$n" "$S/entities"; then :; else echo "$n" >> "$S/entities"; echo "{\"data\":{\"id\":\"ent-$n\",\"name\":\"$n\"}}"; fi ;;
  "GET identity/entity/name/"*)
    n=${path#identity/entity/name/}
    grep -qx "$n" "$S/entities" || { echo '{"errors":[]}'; exit 22; }
    echo "{\"data\":{\"id\":\"ent-$n\",\"name\":\"$n\",\"metadata\":{\"cluster\":\"${n#cluster-}\"}}}" ;;
  "DELETE identity/entity/name/"*) grep -vx "${path#identity/entity/name/}" "$S/entities" > "$S/e" || true; mv "$S/e" "$S/entities"; echo '{}' ;;
  "GET "*) echo "unexpected GET $path" >&2; exit 1 ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "$bin/kubectl" "$bin/curl"
run() {  # run <clusters> [env...] -> output in $out, status in $st, calls in $tmp/calls
  printf '%b' "$1" > "$tmp/clusters"; : > "$tmp/calls"; : > "$tmp/argv"; : > "$tmp/bodies"; shift
  printf 'k8s-dev1 auth_kubernetes_dev1\nk8s-old auth_kubernetes_old\n' > "$tmp/mounts"
  printf 'cluster-dev1\ncluster-old\n' > "$tmp/entities"
  set +e; out=$(env PATH="$bin:$PATH" STUB_DIR="$tmp" SA_DIR="$tmp/sa" "$@" bash "$script" 2>&1); st=$?; set -e
}
has() { grep -q -- "$1" <<<"$out" || fail "${2:-expected '$1'}: $out"; }
hasnt() { ! grep -q -- "$1" <<<"$out" || fail "${2:-unexpected '$1'}: $out"; }
at() { local n; n=$(grep -nxF -m1 -- "$1" "$tmp/calls" | cut -d: -f1); echo "${n:-0}"; }   # line of a call, 0 if none

# 1. DRY_RUN: dev1 ready, dev9 without endpoint, dev7 without projected CA
run 'dev1 172.23.0.3 6443\ndev9  \ndev7 172.23.0.9 6443\n' DRY_RUN=1
[ "$st" = 0 ] || fail "DRY_RUN exit $st: $out"
has 'DRY_RUN: POST /v1/auth/k8s-dev1/config .*"kubernetes_host":"https://172.23.0.3:6443".*"disable_local_ca_jwt":true'
hasnt 'DRY_RUN: POST /v1/sys/auth/k8s-dev1' "k8s-dev1 exists already, must not be re-enabled"
has 'DRY_RUN: POST /v1/identity/entity/name/cluster-dev1 {"metadata":{"cluster":"dev1"}}'
has 'DRY_RUN: POST /v1/identity/entity-alias {"name":"external-secrets/external-secrets","mount_accessor":"auth_kubernetes_dev1","canonical_id":"ent-cluster-dev1"}'
has 'DRY_RUN: POST /v1/auth/k8s-dev1/role/eso .*"bound_service_account_names":"external-secrets".*"token_policies":"cluster-reader"'
has 'DRY_RUN: POST /v1/auth/k8s-dev1/role/eso .*"alias_name_source":"serviceaccount_name"'
has '^ensured k8s-dev1'
has '^skipped dev9: no controlPlaneEndpoint' && has '^skipped dev7: no openbao/dev7-ca-public'
has 'DRY_RUN: DELETE /v1/identity/entity/name/cluster-old' && has 'DRY_RUN: DELETE /v1/sys/auth/k8s-old'
hasnt 'DELETE /v1/sys/auth/k8s-dev[79]' "clusters being born must keep their mounts"
hasnt 'sys/policies' "fleet-sync writes no policies"
hasnt 'FAKE CA' "CA must not be logged"

# 2. real mode: dev6 new, dev8 fails -> the others still converge, cleanup still runs, exit 1, token only via header file
run 'dev1 172.23.0.3 6443\ndev8 172.23.0.8 6443\ndev6 172.23.0.6 6443\n'
[ "$st" = 1 ] || fail "one failing cluster must exit 1, got $st: $out"
has '^failed dev8' && has '^ensured k8s-dev1' && has '^ensured k8s-dev6' && has '^removed k8s-old'
[ "$(at 'POST sys/auth/k8s-dev6')" != 0 ] || fail "new cluster dev6: mount not enabled"
# existing mount: config (CA + endpoint) is still rewritten every run - a reborn cluster's new CA lands within one run
[ "$(at 'POST auth/k8s-dev1/config')" != 0 ] || fail "existing k8s-dev1: config not rewritten"
grep -q 'kubernetes_ca_cert":"FAKE CA".*auth/k8s-dev1/config$' "$tmp/argv" || fail "k8s-dev1 config doesn't carry the projected CA"
# new cluster: the alias (-> entity with metadata) exists before role eso, so no ESO login can create a stray entity
m=$(at 'POST sys/auth/k8s-dev6'); e=$(at 'POST identity/entity/name/cluster-dev6'); r=$(at 'POST auth/k8s-dev6/role/eso')
grep -q '^POST identity/entity-alias {"name":"external-secrets/external-secrets","mount_accessor":"auth_kubernetes_dev6","canonical_id":"ent-cluster-dev6"}$' "$tmp/bodies" ||
  fail "dev6 alias: $(grep entity-alias "$tmp/bodies")"
alias_line=$(awk -v r="$r" '$0 == "POST identity/entity-alias" && NR < r {n = NR} END {print n + 0}' "$tmp/calls")
[ "$m" -lt "$e" ] && [ "$e" -lt "$alias_line" ] && [ "$alias_line" -lt "$r" ] ||
  fail "dev6 order must be mount($m) < entity($e) < alias($alias_line) < role($r): $(cat "$tmp/calls")"
# gone cluster: entity first (its aliases go with it), then the mount; a failed entity delete keeps the mount for a retry
[ "$(at 'DELETE identity/entity/name/cluster-old')" -lt "$(at 'DELETE sys/auth/k8s-old')" ] || fail "cluster-old: entity must go before the mount"
! grep -q 'sys/policies' "$tmp/calls" || fail "fleet-sync must not touch policies: $(grep sys/policies "$tmp/calls")"
[ "$(at 'POST auth/token/revoke-self')" != 0 ] || fail "token not revoked at exit"
! grep -q 's.faketoken\|fake-jwt' "$tmp/argv" || fail "token/JWT on curl's argv"
grep -q -- '-H @' "$tmp/argv" || fail "token header not passed as a file"

# every path the script touches (bar login/revoke-self) is granted by the fleet-sync policy ...
patterns=$(sed -n 's/^path "\([^"]*\)".*/\1/p' <<<"$policy")
match() {  # match <api path> -> the policy path pattern that grants it (last match wins, like a longest-prefix guess)
  local p m=""
  # shellcheck disable=SC2053  # unquoted on purpose: policy paths are globs
  for p in $patterns; do [[ "$1" == ${p//+/[!\/]*} ]] && m=$p; done
  echo "$m"
}
while read -r method path; do
  path=${path%%\?*}
  case "$path" in auth/kubernetes/login|auth/token/revoke-self) continue ;; esac
  [ -n "$(match "$path")" ] || fail "fleet-sync policy doesn't cover $method $path (policy paths: $(tr '\n' ' ' <<<"$patterns"))"
done < "$tmp/calls"
# ... and so is every parameter it sends: allowed_parameters of the matching path lists each key, and a key with a
# non-empty list only accepts those values (OpenBao compares the whole value)
allowed=$tmp/allowed   # "<path pattern>\t<key>\t<values>" from the policy
awk '
  /^path "/ { split($0, a, "\""); p = a[2] }
  /allowed_parameters = \{/ { inb = 1 }
  inb {
    s = $0
    while (match(s, /"[a-z_]+" = \[[^]]*\]/)) {
      kv = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
      k = kv; sub(/^"/, "", k); sub(/".*/, "", k)
      v = kv; sub(/^[^[]*\[/, "", v); sub(/\]$/, "", v)
      print p "\t" k "\t" v
    }
    if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /allowed_parameters = \{[^}]*$/ || $0 ~ /allowed_parameters = \{.*\}/) inb = 0
  }' <<<"$policy" > "$allowed"
[ -s "$allowed" ] || fail "could not parse allowed_parameters from the fleet-sync policy"
while read -r method path body; do
  p=$(match "$path")
  [ -n "$p" ] || continue
  grep -q "^$(printf '%s' "$p" | sed 's/[*.]/\\&/g')	" "$allowed" || fail "$method $path sends a body but $p has no allowed_parameters"
  for k in $(jq -r 'keys[]' <<<"$body"); do
    line=$(awk -F'\t' -v p="$p" -v k="$k" '$1 == p && $2 == k' "$allowed")
    [ -n "$line" ] || fail "$method $path: parameter $k not in allowed_parameters of $p"
    vals=$(cut -f3 <<<"$line")
    [ -n "$vals" ] || continue
    v=$(jq -c --arg k "$k" '.[$k]' <<<"$body")
    [[ ",$(tr -d ' ' <<<"$vals")," == *",$v,"* ]] || fail "$method $path: $k=$v not in allowed [$vals] of $p"
  done
done < "$tmp/bodies"
# entities: fleet-sync may only touch entities named cluster-*, and only their metadata (no policies on an entity)
assert_allowed() { awk -F'\t' -v p="$1" '$1 == p {print $2}' "$allowed" | sort | paste -sd, -; }
[ "$(assert_allowed 'identity/entity/name/cluster-*')" = metadata ] || fail "entity writes: only metadata, got $(assert_allowed 'identity/entity/name/cluster-*')"
[ "$(assert_allowed 'identity/entity-alias')" = canonical_id,mount_accessor,name ] || fail "alias writes: $(assert_allowed 'identity/entity-alias')"

# 3. empty cluster list while k8s-* mounts exist: log and leave OpenBao alone
run ''
[ "$st" = 0 ] || fail "empty list exit $st: $out"
has '^refusing cleanup: no worker clusters listed but 2 k8s-\* mounts exist'
! grep -q '^DELETE' "$tmp/calls" || fail "empty list must not delete anything: $(cat "$tmp/calls")"
true
