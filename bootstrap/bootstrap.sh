#!/usr/bin/env bash
# Imperative part ends here: kind + Argo CD + root app. Argo then adopts itself (mgmt-argo-cd) and installs the rest.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in docker kind kubectl helm; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done

kind get clusters | grep -qx mgmt || kind create cluster --config bootstrap/kind-mgmt.yaml
kubectl config use-context kind-mgmt

helm dependency build repos/platform-charts/argo-cd
# Chart defaults only. Hub-specific values (redis proxy for argocd-agent etc.) arrive via GitOps.
helm upgrade --install argocd repos/platform-charts/argo-cd \
  --namespace argocd --create-namespace --wait --timeout 10m

kubectl apply -f bootstrap/root-app.yaml

echo
echo "Argo CD : http://localhost:8080  (admin / \$(make argocd-password))"
echo "Kargo   : http://localhost:8081  (admin / admin)"
echo "Watch   : kubectl get applications -n argocd -w"
