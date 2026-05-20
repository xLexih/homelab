#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="EXAMPLE"

echo "==> Applying manifests..."
kubectl apply -f "${SCRIPT_DIR}/deploy.yaml"

echo "==> EXAMPLE deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
