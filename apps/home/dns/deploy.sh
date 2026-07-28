#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="dns"

echo "==> Applying DNS updater manifests..."
kubectl apply -f "${SCRIPT_DIR}/deploy.yaml"

echo "==> Waiting for rollout..."
kubectl -n "${NAMESPACE}" rollout status deployment/dns-update --timeout=120s

echo "==> DNS updater deployed successfully!"
kubectl -n "${NAMESPACE}" get pods,svc
