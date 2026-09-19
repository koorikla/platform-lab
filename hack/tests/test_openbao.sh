#!/usr/bin/env bash
# OpenBao on the hub (#30): raft on a PVC, static-key auto-unseal (key generated in-cluster into a hub Secret by the
# unseal-key init container), declarative self-init (bootstrap only, root token revoked, no recovery keys) and the
# `configure` sidecar that applies the rest idempotently. API on NodePort 30820 (workers reach it via mgmt-lb),
# hub-writer ClusterSecretStore. The init and configure scripts run here against stubbed kubectl/bao.
source "$(dirname "$0")/lib.sh"
o=$(render openbao $charts/openbao -n openbao -f $config/addons/management/openbao/values.yaml)
sts='select(.kind=="StatefulSet")'
assert_yq "$o" "[$sts] | length" 1
# only the API port is published (the chart Service also carries 8201, cluster-internal)
assert_yq "$o" '[select(.kind=="Service" and .spec.type=="NodePort")] | length' 1
assert_yq "$o" 'select(.kind=="Service" and .spec.type=="NodePort") | [.spec.ports[] | .port + ":" + .nodePort] | join(",")' 8200:30820
assert_yq "$o" 'select(.kind=="Service" and .spec.type=="NodePort") | .spec.selector | to_entries | map(.key + "=" + .value) | sort | join(",")' \
  "$(yq "$sts | .spec.selector.matchLabels | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" "$o")"
# ... and mgmt-lb forwards 30820 to it
lb=$(yq '.data.value' $config/fleet/base/hub-lb.yaml)
grep -qE '^ *bind \*:30820$' <<<"$lb" || fail "hub-lb.yaml: no frontend bound to :30820"
grep -qF 'JoinHostPort $backend.Address "30820"' <<<"$lb" || fail "hub-lb.yaml: no backend on node port 30820"
# openbao = hub-writer (argocd only); default = OpenChoreo's read-only store (test_openchoreo_secrets.sh)
assert_yq "$o" '[select(.kind=="ClusterSecretStore") | .metadata.name] | sort | join(",")' default,openbao
assert_yq "$o" 'select(.kind=="ClusterSecretStore" and .metadata.name=="openbao") | .spec.provider.vault.server' http://openbao.openbao.svc:8200
assert_yq "$o" 'select(.kind=="ClusterSecretStore" and .metadata.name=="openbao") | .spec.provider.vault.auth.kubernetes.role' hub-writer

# --- server: no dev mode, no postStart; data on a PVC (hub default StorageClass = local-path); auto-unseal lets a
#     config change roll the pod (RollingUpdate + config checksum)
srv="$sts | .spec.template.spec.containers[] | select(.name==\"openbao\")"
assert_yq "$o" "$srv | .args | join(\" \") | test(\"server -dev\")" false
assert_yq "$o" "[$srv | .env[] | select(.name | test(\"DEV\"))] | length" 0
assert_yq "$o" "$srv | .lifecycle.postStart" null
assert_yq "$o" "$sts | .spec.updateStrategy.type" RollingUpdate
assert_yq "$o" "$sts | .spec.replicas" 1
assert_yq "$o" "$sts | .spec.template.metadata.annotations | has(\"openbao.hashicorp.com/config-checksum\")" true
assert_yq "$o" "$sts | .spec.volumeClaimTemplates | map(.metadata.name + \":\" + .spec.resources.requests.storage) | join(\",\")" data:1Gi
assert_yq "$o" "$sts | .spec.volumeClaimTemplates[0].spec.storageClassName" null
cfg=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-config") | .data["extraconfig-from-values.hcl"]' "$o")
[ -n "$cfg" ] || fail "no server config (ConfigMap openbao-config)"
grep -qE '^storage "raft" \{' <<<"$cfg" || fail "server config: storage must be raft: $cfg"
grep -qE '^ *path += "/openbao/data"' <<<"$cfg" || fail "raft must live on the data PVC mount"
# the chart's start script sed-replaces these words in the config: they must not appear by accident
! grep -qE 'HOST_IP|POD_IP|HOSTNAME|API_ADDR|TRANSIT_ADDR|RAFT_ADDR' <<<"$cfg" || fail "server config contains a word the chart's start script rewrites"

# --- static seal: key file from the in-memory volume the init container fills, never a literal
seal=$(awk '/^seal "static"/ {f=1} f {print} f && /^}/ {exit}' <<<"$cfg")
[ -n "$seal" ] || fail "server config: no seal \"static\" stanza"
grep -qE 'current_key += "file:///openbao/unseal/key"' <<<"$seal" || fail "static seal must read the key file: $seal"
grep -qE 'current_key_id += "[A-Za-z0-9._-]+"' <<<"$seal" || fail "static seal needs current_key_id: $seal"
vol() { yq "$sts | .spec.template.spec.volumes[] | select(.name==\"$1\") | $2" "$o"; }
[ "$(vol unseal .emptyDir.medium)" = Memory ] || fail "unseal volume must be an in-memory emptyDir"
[ "$(vol configure .configMap.name)" = openbao-configure ] || fail "configure volume must be ConfigMap openbao-configure"
mnt() { yq "$sts | .spec.template.spec.$1[] | select(.name==\"$2\") | .volumeMounts[] | select(.name==\"$3\") | .mountPath + \":\" + (.readOnly // false)" "$o"; }
[ "$(mnt containers openbao unseal)" = /openbao/unseal:true ] || fail "server: unseal volume at /openbao/unseal, read-only"
[ "$(mnt containers openbao configure)" = /openbao/configure:true ] || fail "server: configure volume (self-init reads its policy)"

# --- self-init: bootstrap only - the configure login and nothing else (a failed self-init refuses to unseal)
init=$(awk '/^initialize "/ {f=1} f {print}' <<<"$cfg")
[ -n "$init" ] || fail "server config: no initialize stanza"
assert_req() { grep -qE "$1" <<<"$init" || fail "self-init: $2"; }
assert_req 'path += "sys/auth/kubernetes"' "must enable kubernetes auth"
assert_req 'path += "auth/kubernetes/config"' "must configure kubernetes auth"
assert_req 'path += "sys/policies/acl/openbao-config"' "must write policy openbao-config"
assert_req 'path += "/openbao/configure/openbao-config.hcl"' "policy openbao-config must come from the configure ConfigMap (one source)"
assert_req 'path += "auth/kubernetes/role/openbao-config"' "must create role openbao-config"
assert_req 'bound_service_account_names += "openbao"' "role openbao-config: server SA only"
assert_req 'bound_service_account_namespaces += "openbao"' "role openbao-config: openbao namespace only"
[ "$(grep -cE '^ *request "' <<<"$init")" = 4 ] || fail "self-init must stay the 4 bootstrap requests: $init"
! grep -q allow_failure <<<"$init" || fail "self-init bootstrap requests must not be allowed to fail"
cm=$tmp/configure; mkdir -p "$cm"
for k in $(yq 'select(.kind=="ConfigMap" and .metadata.name=="openbao-configure") | .data | keys | .[]' "$o"); do
  yq "select(.kind==\"ConfigMap\" and .metadata.name==\"openbao-configure\") | .data[\"$k\"]" "$o" > "$cm/$k"
done
[ -s "$cm/openbao-config.hcl" ] || fail "ConfigMap openbao-configure: no openbao-config.hcl"
[ -s "$cm/configure.sh" ] || fail "ConfigMap openbao-configure: no configure.sh"

# --- unseal-key init container: create-only, never overwrites; the Secret is outside Argo (no prune/cascade)
ic="$sts | .spec.template.spec.initContainers[] | select(.name==\"unseal-key\")"
assert_yq "$o" "[$ic] | length" 1
assert_yq "$o" "$ic | .image" "$(yq '.fleetSync.image' $charts/openbao/values.yaml)"
[ "$(mnt initContainers unseal-key unseal)" = /openbao/unseal:false ] || fail "init: writes the unseal volume"
[ "$(mnt initContainers unseal-key data)" = /openbao/data:true ] || fail "init: reads the data PVC (refuses a new key over existing data)"
ukey=$tmp/unseal-key.sh; yq "$ic | .args[0]" "$o" > "$ukey"
[ "$(yq "$ic | .command | join(\" \")" "$o")" = "/bin/sh -ec" ] || fail "init: command must be /bin/sh -ec"
if command -v shellcheck >/dev/null; then shellcheck -s sh "$ukey" || fail "shellcheck unseal-key"; fi
! grep -qE 'kubectl (apply|replace|patch|delete|edit)' "$ukey" || fail "unseal-key must only get/create: $(cat "$ukey")"
secret=$(yq "$ic | .env[] | select(.name==\"SECRET\") | .value" "$o")
[ "$secret" = openbao-unseal-key ] || fail "init: SECRET env = $secret"
# nothing in this chart may read Secrets in openbao by namespace (unseal key, openchoreo-* sources): every get/list/
# watch rule on secrets is name-scoped
assert_yq "$o" '[select(.kind=="Role" or .kind=="ClusterRole") | .rules[] | select((.resources // []) | contains(["secrets"])) |
  select((.verbs | contains(["list"])) or (.verbs | contains(["watch"])) or ((.verbs | contains(["get"])) and ((.resourceNames // []) | length == 0)))] | length' 0
# the server SA may read exactly that Secret and create Secrets; nothing else
role='select(.kind=="Role" and .metadata.name=="openbao-unseal-key")'
assert_yq "$o" "$role | .rules | map(.verbs | join(\",\")) | sort | join(\"|\")" "create|get"
assert_yq "$o" "$role | .rules[] | select(.verbs[0]==\"get\") | .resourceNames | join(\",\")" "$secret"
assert_yq "$o" "[$role | .rules[].resources[]] | unique | join(\",\")" secrets
assert_yq "$o" 'select(.kind=="RoleBinding" and .metadata.name=="openbao-unseal-key") | .subjects | map(.kind + "/" + .name) | join(",")' \
  "ServiceAccount/$(yq "$sts | .spec.template.spec.serviceAccountName" "$o")"

bin=$tmp/ubin; mkdir -p "$bin"
cat > "$bin/kubectl" <<'STUB'
#!/usr/bin/env bash
set -o pipefail
echo "$*" >> "$STUB_DIR/kubectl"
case "$*" in
  "get secret openbao-unseal-key -n openbao --ignore-not-found -o jsonpath={.data.key}")
    [ ! -f "$STUB_DIR/secret" ] || cat "$STUB_DIR/secret" ;;
  "create secret generic openbao-unseal-key -n openbao --from-file=key="*)
    f=${*: -1}; base64 < "${f#--from-file=key=}" | tr -d '\n' > "$STUB_DIR/secret" || exit 1 ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$bin/kubectl"
ukrun() {  # ukrun -> $st, $out; key in $tmp/u/unseal/key
  : > "$tmp/kubectl"
  set +e; out=$(env PATH="$bin:$PATH" STUB_DIR="$tmp" SECRET=openbao-unseal-key NAMESPACE=openbao \
    KEY_FILE="$tmp/u/unseal/key" DATA_DIR="$tmp/u/data" sh -ec "$(cat "$ukey")" 2>&1); st=$?; set -e
}
mkdir -p "$tmp/u/unseal" "$tmp/u/data"
# 1. first boot: no Secret, empty PVC -> 32 random bytes, base64 (44 chars, a format the static seal decodes), Secret
ukrun
[ "$st" = 0 ] || fail "unseal-key first boot exit $st: $out"
[ "$(wc -c < "$tmp/u/unseal/key" | tr -d ' ')" = 44 ] || fail "key file must be 44 base64 chars (no newline): $(wc -c < "$tmp/u/unseal/key")"
[ "$(base64 -d < "$tmp/u/unseal/key" | wc -c | tr -d ' ')" = 32 ] || fail "key must decode to 32 bytes"
# GNU stat first: on Linux `stat -f` is filesystem status and succeeds with other output
[ "$(stat -c %a "$tmp/u/unseal/key" 2>/dev/null || stat -f %Lp "$tmp/u/unseal/key")" = 400 ] || fail "key file must be 0400"
first=$(cat "$tmp/u/unseal/key")
! grep -qF "$first" <<<"$out$(cat "$tmp/kubectl")" || fail "key on stdout or kubectl argv"
# 2. restart (key file still there from an earlier init attempt, 0400): Secret exists -> same key, no create
touch "$tmp/u/data/vault.db"
ukrun
[ "$st" = 0 ] || fail "unseal-key restart exit $st: $out"
[ "$(cat "$tmp/u/unseal/key")" = "$first" ] || fail "restart must restore the stored key"
! grep -q '^create' "$tmp/kubectl" || fail "restart must not create a Secret"
# 3. Secret gone but raft data present: a new key could never unseal it -> refuse, create nothing
rm -f "$tmp/secret" "$tmp/u/unseal/key"
ukrun
[ "$st" != 0 ] || fail "missing Secret over existing data must fail"
grep -q 'openbao-unseal-key' <<<"$out" || fail "refusal must name the Secret: $out"
! grep -q '^create' "$tmp/kubectl" || fail "refusal must not create a Secret"
[ ! -e "$tmp/u/unseal/key" ] || fail "refusal must not leave a key file"

# --- configure sidecar: same image as the server, reruns the ConfigMap script (no readiness probe: a config error
#     must not take the API out of the Service)
sc="$sts | .spec.template.spec.containers[] | select(.name==\"configure\")"
assert_yq "$o" "[$sc] | length" 1
assert_yq "$o" "$sc | .image" "$(yq "$srv | .image" "$o")"
assert_yq "$o" "$sc | .readinessProbe" null
assert_yq "$o" "$sc | [.command[], .args[]] | join(\" \") | test(\"/openbao/configure/configure.sh\")" true
[ "$(mnt containers configure configure)" = /openbao/configure:true ] || fail "configure: reads its ConfigMap"
assert_yq "$o" "$sc | .env[] | select(.name==\"BAO_ADDR\") | .value" http://127.0.0.1:8200
if command -v shellcheck >/dev/null; then shellcheck -s sh "$cm/configure.sh" || fail "shellcheck configure.sh"; fi
! grep -qE 'kv put|kv patch|/v1/secret/data' "$cm/configure.sh" || fail "configure writes KV data (values belong in generators/PushSecrets)"

# stub bao: records "<METHOD> <api path>" (what the CLI would call) and fails without a token where OpenBao would
cbin=$tmp/cbin; mkdir -p "$cbin" "$tmp/csa"; printf 'fake-jwt' > "$tmp/csa/token"
cat > "$cbin/bao" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/bao-argv"
call() { echo "$1 $2" >> "$STUB_DIR/bao-calls"; }
authd() { [ "${BAO_TOKEN:-}" = s.cfgtoken ] || { echo "permission denied (no token) for $*" >&2; exit 2; }; }
case "$1 $2" in
  "status "*) [ -f "$STUB_DIR/sealed" ] && exit 2; exit 0 ;;
  "write -field=token")
    [ "$3 $4" = "auth/kubernetes/login role=openbao-config" ] && [ "$5" = "jwt=@$SA_DIR/token" ] || { echo "bad login: $*" >&2; exit 2; }
    call POST auth/kubernetes/login; echo s.cfgtoken ;;
  "secrets list") authd; call GET sys/mounts; cat "$STUB_DIR/mounts" ;;
  "secrets enable") authd; call POST sys/mounts/secret ;;
  "policy write") authd; call PUT "sys/policies/acl/$3"; [ -s "$4" ] || { echo "empty policy file $4" >&2; exit 2; }
    echo "$3" >> "$STUB_DIR/bao-policies" ;;
  "token revoke") authd; call POST auth/token/revoke-self ;;
  write*) authd; call POST "$2" ;;
  *) echo "unexpected bao $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$cbin/bao"
crun() {  # crun <mounts table> -> $st, $out
  printf '%b' "$1" > "$tmp/mounts"; : > "$tmp/bao-calls"; : > "$tmp/bao-argv"; : > "$tmp/bao-policies"
  set +e; out=$(env PATH="$cbin:$PATH" STUB_DIR="$tmp" SA_DIR="$tmp/csa" CONF_DIR="$cm" BAO_K8S_NAMESPACE=openbao BAO_SA=openbao \
    sh "$cm/configure.sh" 2>&1); st=$?; set -e
}
crun 'Path Type\ncubbyhole/ cubbyhole\nsys/ system\n'
[ "$st" = 0 ] || fail "configure exit $st: $out"
grep -qx 'POST sys/mounts/secret' "$tmp/bao-calls" || fail "configure must enable kv at secret/ on an empty OpenBao"
# every policy file in the ConfigMap is written, under its file name
want=$(cd "$cm" && ls ./*.hcl | sed 's#^\./##; s#\.hcl$##' | sort | paste -sd, -)
[ "$(sort "$tmp/bao-policies" | paste -sd, -)" = "$want" ] || fail "policies written: $(sort "$tmp/bao-policies" | paste -sd, -), want $want"
for r in openbao-config hub-writer fleet-sync openchoreo-seeder openchoreo-reader operator; do
  grep -qx "POST auth/kubernetes/role/$r" "$tmp/bao-calls" || fail "configure: no role $r"
done
grep -qx 'POST auth/token/revoke-self' "$tmp/bao-calls" || fail "configure must revoke its token"
! grep -q 's.cfgtoken\|fake-jwt' "$tmp/bao-argv" || fail "token/JWT on bao's argv"
# existing kv mount: not re-enabled
crun 'Path Type\nsecret/ kv\nsys/ system\n'
[ "$st" = 0 ] || fail "configure (existing kv) exit $st: $out"
! grep -q 'sys/mounts/secret' "$tmp/bao-calls" || fail "existing secret/ mount must not be re-enabled"
# sealed/unreachable: fail fast, no login (the sidecar loop retries)
touch "$tmp/sealed"; crun ''
[ "$st" != 0 ] || fail "configure must fail while sealed"
! grep -q login "$tmp/bao-calls" || fail "configure must not log in while sealed"
rm -f "$tmp/sealed"
# every path configure touches (bar login/revoke-self) is granted by openbao-config.hcl
crun 'Path Type\n'
patterns=$(sed -n 's/^path "\([^"]*\)".*/\1/p' "$cm/openbao-config.hcl")
while read -r method path; do
  case "$path" in auth/kubernetes/login|auth/token/revoke-self) continue ;; esac
  ok=0
  # shellcheck disable=SC2053  # policy paths are globs
  for p in $patterns; do [[ "$path" == ${p//+/[!\/]*} ]] && ok=1; done
  [ "$ok" = 1 ] || fail "openbao-config policy doesn't cover $method $path"
done < "$tmp/bao-calls"
# configure owns the openbao-config role too: same binding as the self-init bootstrap
line=$(grep -A1 'auth/kubernetes/role/openbao-config ' "$cm/configure.sh" | tr -d '\\\n' | tr -s ' ')
grep -q 'token_policies=openbao-config ' <<<"$line" || fail "role openbao-config: $line"
grep -q 'bound_service_account_names="$BAO_SA"' <<<"$line" || fail "role openbao-config must bind the server SA: $line"
assert_yq "$o" "$sc | .env[] | select(.name==\"BAO_SA\") | .value" "$(yq "$sts | .spec.template.spec.serviceAccountName" "$o")"

# --- humans: role operator (SA openbao-operator, no pod uses it) may only touch hand-written hub material
assert_yq "$o" '[select(.kind=="ServiceAccount" and .metadata.name=="openbao-operator")] | length' 1
! grep -vE '^ *(#|$)' "$cm/operator.hcl" | grep -v 'secret/[a-z]*/hub/' | grep -q path || fail "operator policy reaches beyond secret/*/hub/: $(cat "$cm/operator.hcl")"
grep -qE '^bao:' Makefile || fail "Makefile: no bao target (operator shell)"
mk=$(awk '/^bao:/ {f=1; print; next} f && /^\t/ {print; next} f {exit}' Makefile)
grep -q 'create token openbao-operator' <<<"$mk" || fail "make bao must use a short-lived openbao-operator token: $mk"
! grep -qE 'jwt=\$|JWT=' <<<"$mk" || fail "make bao must not put the JWT on an argv: $mk"

# --- make openbao-key-backup: the unseal key goes to a 0600 file outside the repo, never to the terminal
kb=$tmp/kbin; mkdir -p "$kb"
cat > "$kb/kubectl" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "--context mgmt -n openbao get secret openbao-unseal-key -o json" ] || { echo "unexpected kubectl $*" >&2; exit 1; }
echo '{"apiVersion":"v1","kind":"Secret","type":"Opaque","metadata":{"name":"openbao-unseal-key","namespace":"openbao","uid":"u","resourceVersion":"1","managedFields":[]},"data":{"key":"S0VZTUFURVJJQUw="}}'
STUB
chmod +x "$kb/kubectl"
backup() { set +e; out=$(env PATH="$kb:$PATH" make -s openbao-key-backup OUT="$1" 2>&1); st=$?; set -e; }
backup "$PWD/unseal-backup.json"
[ "$st" != 0 ] && grep -q 'inside the repo' <<<"$out" && [ ! -e unseal-backup.json ] || fail "backup into the repo must be refused: $out"
backup "$tmp/bk/key.json"
[ "$st" = 0 ] || fail "backup exit $st: $out"
! grep -q 'S0VZTUFURVJJQUw=' <<<"$out" || fail "backup printed the key"
[ "$(stat -c %a "$tmp/bk/key.json" 2>/dev/null || stat -f %Lp "$tmp/bk/key.json")" = 600 ] || fail "backup file must be 0600"
[ "$(jq -c '[.metadata | keys[]], .data.key' "$tmp/bk/key.json" | paste -sd' ' -)" = '["name","namespace"] "S0VZTUFURVJJQUw="' ] ||
  fail "backup must be a re-creatable Secret (name/namespace/data only): $(jq -c .metadata "$tmp/bk/key.json")"
backup "$tmp/bk/key.json"
[ "$st" != 0 ] && grep -q 'exists' <<<"$out" || fail "backup must not overwrite: $out"
