#!/usr/bin/env bash
# Lower steady load on the shared Docker VM (#76): the hub Argo CD refreshes less often and runs fewer app processors,
# workers run a small-profile Argo CD, and Kargo verification (one Job + pod on the hub per measurement) measures every
# 60 s instead of 30 s. Each chart's settings: its unit tests (argo-cd/tests/load_test.yaml,
# worker-birth-kit/tests/argo_cd_load_test.yaml, kargo-pipeline/tests/verification_test.yaml). Here: the cross-chart
# contract - verification's window still covers the worker's repo poll, a rollout and the healthy streak.
source "$(dirname "$0")/lib.sh"
cm='select(.kind=="ConfigMap" and .metadata.name=="argocd-cm") | .data'

# the worker's Argo CD as the birth kit HelmChartProxy renders it
yq 'select(.kind=="HelmChartProxy") | .spec.valuesTemplate' $config/fleet/base/helmchartproxies.yaml |
  sed 's/{{ \.Cluster\.metadata\.name }}/dev1/g' > "$tmp/kit-values.yaml"
w=$(render worker-birth-kit $charts/worker-birth-kit -n argocd -f "$tmp/kit-values.yaml")

k=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager)
m='select(.kind=="AnalysisTemplate") | .spec.metrics[0]'
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
