#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="apisix"
RELEASE_NAME="apisix"
CHART="apisix/apisix"
CHART_VERSION="2.13.0"

echo "==> Adding/updating Apisix Helm repo..."
helm repo add apisix https://apache.github.io/apisix-helm-chart 2>/dev/null || true
helm repo update apisix

echo "==> Installing/upgrading Apisix..."
helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
  --namespace "${NAMESPACE}" --create-namespace \
  --version "${CHART_VERSION}" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --history-max 3 \
  --timeout 10m

echo "==> Applying manifests..."
kubectl apply -f "${SCRIPT_DIR}/pdb.yaml"
kubectl apply -f "${SCRIPT_DIR}/gateway-udp.yaml"

echo "==> Apisix deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
