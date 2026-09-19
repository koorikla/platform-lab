#!/usr/bin/env bash
# Hub stability under CPU starvation (#76): the embedded controllers' leader election outlasts a slow apiserver/etcd
# instead of taking the whole k3s process down ("leaderelection lost" -> exit 1), and the hub LB doesn't mark a slow
# apiserver DOWN after 2 s. Load reduction: test_hub_load.sh.
# Flag semantics are pinned to k3s v1.34.11 / cluster-api-k3s v0.4.0 (see the ClusterClass comments).
source "$(dirname "$0")/lib.sh"
cc=$config/fleet/base/clusterclasses/k3s-docker.yaml
class='select(.kind=="ClusterClass")'

# --- ClusterClass variable: opt-in per cluster, default off, so adding it rolls no existing control plane
v="$class | .spec.variables[] | select(.name==\"slowHostTolerance\")"
assert_yq "$cc" "$v | .schema.openAPIV3Schema.type" boolean
assert_yq "$cc" "$v | .schema.openAPIV3Schema.default" false
p="$class | .spec.patches[] | select(.name==\"slowHostTolerance\")"
assert_yq "$cc" "$p | .enabledIf" '{{ .slowHostTolerance }}'
# control plane only: agents (workers' k3s-agent) run no controllers and no etcd
assert_yq "$cc" "$p | .definitions | length" 1
assert_yq "$cc" "$p | .definitions[0].selector | .kind + \" \" + (.matchResources.controlPlane | tostring)" \
  "KThreesControlPlaneTemplate true"
assert_yq "$cc" "$p | .definitions[0].jsonPatches | map(.op + \" \" + .path) | join(\",\")" \
  "add /spec/template/spec/kthreesConfigSpec/files"
# the patch owns the whole files list: the base template must not have one it would replace
assert_yq "$cc" 'select(.kind=="KThreesControlPlaneTemplate") | .spec.template.spec.kthreesConfigSpec.files' null
f="$p | .definitions[0].jsonPatches[0].value"
assert_yq "$cc" "$f | length" 1
# a k3s config drop-in (k3s reads config.yaml.d/*.yaml after config.yaml, in name order)
assert_yq "$cc" "$f | .[0].path | test(\"^/etc/rancher/k3s/config.yaml.d/[a-z0-9-]+\\\\.yaml\$\")" true
yq "$class | .spec.patches[] | select(.name==\"slowHostTolerance\") | .definitions[0].jsonPatches[0].value[0].content" \
  "$cc" > "$tmp/dropin.yaml"
# "<key>+" appends to config.yaml's list (cluster-api-k3s writes kube-controller-manager-arg: [cloud-provider=external]
# there); a plain key would replace it
for k in kube-controller-manager-arg kube-scheduler-arg kube-cloud-controller-manager-arg; do
  [ "$(yq "has(\"$k\")" "$tmp/dropin.yaml")" = false ] || fail "drop-in: $k replaces config.yaml's list, use $k+"
  args=$(yq ".\"$k+\" | .[]" "$tmp/dropin.yaml")
  get() { sed -n "s/^leader-elect-$1=\([0-9]*\)s\$/\1/p" <<<"$args"; }
  lease=$(get lease-duration) renew=$(get renew-deadline) retry=$(get retry-period)
  [ -n "$lease" ] && [ -n "$renew" ] && [ -n "$retry" ] || fail "$k: lease-duration, renew-deadline, retry-period in seconds: $args"
  # client-go: leaseDuration > renewDeadline > 1.2 x retryPeriod (JitterFactor), else the component refuses to start
  [ "$lease" -gt "$renew" ] && [ $((renew * 10)) -gt $((retry * 12)) ] || fail "$k: invalid leader-election timings: $args"
  # the point: survive an apiserver/etcd stall far longer than the 10 s default renew deadline
  [ "$renew" -ge 30 ] || fail "$k: renew-deadline ${renew}s, want >= 30s"
done
# only those three keys: etcd already runs with heartbeat 500 ms / election 5000 ms in k3s (pkg/etcd/etcd.go)
assert_yq "$tmp/dropin.yaml" 'keys | sort | join(",")' \
  "kube-cloud-controller-manager-arg+,kube-controller-manager-arg+,kube-scheduler-arg+"

# clusters not born yet get it at birth, when it costs no rollout. Named, not every *.disabled: renaming a file to
# .disabled keeps its Cluster running, and such a file would roll that control plane when re-enabled (dev2 is decided
# in the #76 rollout plan).
for ff in nit/nit1 sit/sit1 prod/prod1; do
  assert_yq "$config/fleet/clusters/$ff.yaml.disabled" '.variables[] | select(.name=="slowHostTolerance") | .value' true
done
shopt -s nullglob
# every fleet file that sets it passes a boolean (the chart copies variables verbatim into the Cluster)
for ff in $config/fleet/clusters/*/*.yaml $config/fleet/clusters/*/*.yaml.disabled; do
  t=$(yq '.variables // [] | .[] | select(.name=="slowHostTolerance") | .value | tag' "$ff")
  [ -z "$t" ] || [ "$t" = '!!bool' ] || fail "$ff: slowHostTolerance must be a boolean, got $t"
done

# --- hub LB: a slow /healthz must not take the only apiserver out of rotation within seconds (default: 2 s check
# timeout, 3 failures -> DOWN -> every client through mgmt-lb gets EOF)
lb=$(yq '.data.value' $config/fleet/base/hub-lb.yaml)
be=$(awk '/^backend kube-apiservers/{on=1; next} /^(backend|frontend) /{on=0} on' <<<"$lb")
grep -qE '^ +timeout check (1[0-9]|[2-9][0-9])s$' <<<"$be" || fail "hub-lb kube-apiservers: want 'timeout check >= 10s'"
grep -qE ' check .*inter [0-9]+s fall [0-9]+ rise 1( |$)' <<<"$be" || fail "hub-lb kube-apiservers: want 'inter <n>s fall <n> rise 1' on the server line"
