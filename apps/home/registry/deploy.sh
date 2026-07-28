#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="registry"

echo "==> Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Adding/updating Helm repos..."
helm repo add twuni https://helm.twun.io 2>/dev/null || true
helm repo add joxit https://helm.joxit.dev 2>/dev/null || true
helm repo update twuni joxit

echo "==> Installing/upgrading Docker Registry..."
helm upgrade --install registry twuni/docker-registry \
  --namespace "${NAMESPACE}" \
  --version "3.0.0" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

echo "==> Installing/upgrading Registry UI..."
helm upgrade --install registry-ui joxit/docker-registry-ui \
  --namespace "${NAMESPACE}" \
  --version "1.1.4" \
  --values "${SCRIPT_DIR}/ui-values.yaml" \
  --wait --timeout 5m

echo "==> Applying LoadBalancer service..."
kubectl apply -f "${SCRIPT_DIR}/deploy.yaml"

echo "==> Registry deployed successfully!"
kubectl -n "${NAMESPACE}" get pods,svc
