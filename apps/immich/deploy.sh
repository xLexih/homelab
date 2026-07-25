#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="immich"
RELEASE_NAME="immich"
CHART="immich/immich"
CHART_VERSION="0.12.0"

echo "==> Applying pre-requisites (namespace, storage, database)..."
kubectl apply -f "${SCRIPT_DIR}/deploy.yaml"

echo "==> Waiting for PostgreSQL to be ready..."
kubectl -n "${NAMESPACE}" rollout status deployment/immich-postgresql --timeout=120s

echo "==> Adding/updating Immich Helm repo..."
helm repo add immich https://immich-app.github.io/immich-charts 2>/dev/null || true
helm repo update immich

echo "==> Installing/upgrading Immich..."
helm upgrade --install "${RELEASE_NAME}" "${CHART}" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 5m

echo "==> Immich deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
