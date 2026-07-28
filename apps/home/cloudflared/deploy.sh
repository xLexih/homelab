#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="cloudflared"
SECRET="${SCRIPT_DIR}/secret.yaml"
MANIFEST="${SCRIPT_DIR}/deploy.yaml"

echo "==> Applying cloudflared manifests..."
kubectl apply -f "${MANIFEST}"

echo "==> cloudflared deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
