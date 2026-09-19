#!/usr/bin/env bash
# Hub Argo CD: a Pending PVC that is a Helm hook (Argo PreSync) is Healthy, so PreSync can reach the later hook that
# consumes it (local-path binds on first consumer). Needed by Thunder's sqlite PVC (#10); otherwise built-in semantics.
# That the override exists: argo-cd chart unit test (tests/pvc_health_test.yaml). Here: its Lua, evaluated by the real
# Argo CD code against the hub's argocd-cm (chart + hub values), when the CLI is around (CI doesn't install it).
source "$(dirname "$0")/lib.sh"
command -v argocd >/dev/null || { echo "skip: argocd CLI not on PATH (Lua not evaluated)"; exit 0; }
h=$(render argocd $charts/argo-cd -n argocd -f $config/addons/management/argo-cd/values.yaml)
cm=$tmp/argocd-cm.yaml; yq 'select(.kind=="ConfigMap" and .metadata.name=="argocd-cm")' "$h" >"$cm"
pvc() {   # pvc <phase> <helm.sh/hook value or ""> -> STATUS reported by argocd admin
  local f; f=$(mktemp "$tmp/pvc.XXXXXX")
  yq -n ".apiVersion=\"v1\" | .kind=\"PersistentVolumeClaim\" | .metadata.name=\"p\" | .status.phase=\"$1\"" >"$f"
  [ -z "$2" ] || yq -i ".metadata.annotations[\"helm.sh/hook\"]=\"$2\"" "$f"
  argocd admin settings resource-overrides health "$f" --argocd-cm-path "$cm" 2>&1 | awk '/^STATUS:/ {print $2}'
}
[ "$(pvc Pending pre-install)" = Healthy ] || fail "hook PVC Pending: $(pvc Pending pre-install), want Healthy"
[ "$(pvc Pending "")" = Progressing ] || fail "plain PVC Pending: $(pvc Pending ""), want Progressing"
[ "$(pvc Bound "")" = Healthy ] || fail "PVC Bound: $(pvc Bound ""), want Healthy"
[ "$(pvc Bound pre-install)" = Healthy ] || fail "hook PVC Bound: $(pvc Bound pre-install), want Healthy"
[ "$(pvc Lost "")" = Degraded ] || fail "PVC Lost: $(pvc Lost ""), want Degraded"
