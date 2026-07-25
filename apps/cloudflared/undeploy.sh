#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="cloudflared"

echo "==> Deleting cloudflared namespace..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "==> cloudflared undeployed successfully!"
