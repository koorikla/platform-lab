#!/usr/bin/env bash
# Imperative part ends here: k3d + Argo CD + root app. Argo then adopts itself (mgmt-argo-cd) and installs the rest.
set -euo pipefail
cd "$(dirname "$0")/.."

for bin in docker k3d kubectl helm; do command -v "$bin" >/dev/null || { echo "missing: $bin"; exit 1; }; done

k3d cluster list mgmt >/dev/null 2>&1 || k3d cluster create --config bootstrap/k3d-mgmt.yaml --wait
kubectl config use-context k3d-mgmt

helm dependency build repos/platform-charts/argo-cd
# Chart defaults only. Hub-specific values (redis proxy for argocd-agent etc.) arrive via GitOps.
helm upgrade --install argocd repos/platform-charts/argo-cd \
  --namespace argocd --create-namespace --wait --timeout 10m

kubectl apply -f bootstrap/root-app.yaml

echo
echo "Argo CD : http://localhost:8080  (admin / \$(make argocd-password))"
echo "Kargo   : http://localhost:8081  (admin / admin)"
echo "Watch   : kubectl get applications -n argocd -w"
