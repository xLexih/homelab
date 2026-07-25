#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="monitoring"
RELEASE_NAME="grafana"
CHART="prometheus-community/kube-prometheus-stack"
CHART_VERSION="86.1.0"

echo "==> Creating namespace..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Adding/updating Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

echo "==> Installing/upgrading kube-prometheus-stack..."
helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 10m

echo "==> Creating speedtest configmaps..."
kubectl create configmap speedtest-controller \
  --namespace "${NAMESPACE}" \
  --from-file=server.py="${SCRIPT_DIR}/speedtest-controller.py" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap speedtest-dashboard \
  --namespace "${NAMESPACE}" \
  --from-file=speedtest.json="${SCRIPT_DIR}/speedtest-dashboard.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap speedtest-dashboard -n "${NAMESPACE}" grafana_dashboard=1 --overwrite

echo "==> Applying speedtest deployments..."
kubectl apply -f "${SCRIPT_DIR}/speedtest.yaml"

echo "==> Monitoring stack deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
