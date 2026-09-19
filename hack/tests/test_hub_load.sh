#!/usr/bin/env bash
# Lower steady load on the shared Docker VM (#76): the hub Argo CD refreshes less often and runs fewer app processors,
# workers run a small-profile Argo CD, and Kargo verification (one Job + pod on the hub per measurement) measures every
# 60 s instead of 30 s while its window still covers the worker's repo poll, a rollout and the healthy streak.
source "$(dirname "$0")/lib.sh"

# --- Argo CD hub: fewer periodic refreshes, bounded burst concurrency
o=$(render argocd $charts/argo-cd -n argocd)
cm='select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data'
params='select(.kind=="ConfigMap" and .metadata.name=="argocd-cmd-params-cm") | .data'
assert_yq "$o" "$cm | .[\"timeout.reconciliation\"]" 300s
assert_yq "$o" "$cm | .[\"timeout.reconciliation.jitter\"]" 60s
assert_yq "$o" "$params | .[\"controller.status.processors\"]" 10
assert_yq "$o" "$params | .[\"controller.operation.processors\"]" 5
# the controller restarts on a params/cm change (argo-helm checksum annotations), or the new values would wait for a restart
assert_yq "$o" 'select(.kind=="StatefulSet" and .metadata.name=="argocd-application-controller") | .spec.template.metadata.annotations | (has("checksum/cmd-params") and has("checksum/cm"))' true

# --- Argo CD worker profile (birth kit): a handful of apps per worker
yq 'select(.kind=="HelmChartProxy") | .spec.valuesTemplate' $config/fleet/base/helmchartproxies.yaml |
  sed 's/{{ \.Cluster\.metadata\.name }}/dev1/g' > "$tmp/kit-values.yaml"
w=$(render worker-birth-kit $charts/worker-birth-kit -n argocd -f "$tmp/kit-values.yaml")
assert_yq "$w" "$cm | .[\"timeout.reconciliation\"]" 180s
assert_yq "$w" "$cm | .[\"timeout.reconciliation.jitter\"]" 60s
assert_yq "$w" "$params | .[\"controller.status.processors\"]" 5
assert_yq "$w" "$params | .[\"controller.operation.processors\"]" 3

# --- Kargo verification: one Job per measurement -> 60 s interval halves the Job churn of the old 30 s
k=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager)
m='select(.kind=="AnalysisTemplate") | .spec.metrics[0]'
assert_yq "$k" "$m | .interval" 60s
secs() { local d; d=$(yq eval-all "$m | .interval" "$k"); case $d in *m) echo $((${d%m} * 60)) ;; *s) echo "${d%s}" ;; esac; }
iv=$(secs); count=$(yq eval-all "$m | .count" "$k"); streak=$(yq eval-all "$m | .consecutiveSuccessLimit" "$k")
# window (count x interval, plus Job runtimes) stays ~12 min: long enough for the worker's slowest repo poll
# (timeout.reconciliation + jitter), a rollout (2 min) and the healthy streak; short enough to fail a bad canary soon
d() { local x; x=$(yq "$cm | .[\"$1\"]" "$w"); echo "${x%s}"; }
poll=$(( $(d timeout.reconciliation) + $(d timeout.reconciliation.jitter) ))
window=$((count * iv))
[ "$window" -ge $((poll + 120 + streak * iv)) ] || fail "verification window ${window}s < worker poll ${poll}s + rollout 120s + streak $((streak * iv))s"
[ "$window" -le 900 ] || fail "verification window ${window}s: keep it ~12 min"
# streak still spans >= 2 min of health (was 4 x 30 s): a canary that crashes after start doesn't pass
[ $(((streak - 1) * iv)) -ge 120 ] || fail "healthy streak spans $(((streak - 1) * iv))s, want >= 120s"
