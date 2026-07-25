#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="EXAMPLE"
MANIFEST="${SCRIPT_DIR}/deploy.yaml"

echo "==> Applying EXAMPLE manifests..."
kubectl apply -f "${MANIFEST}"

echo "==> EXAMPLE deployed successfully!"
kubectl -n "${NAMESPACE}" get pods,svc
