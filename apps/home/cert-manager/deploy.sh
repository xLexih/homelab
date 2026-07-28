#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="cert-manager"
CERT_MANAGER_RELEASE="cert-manager"
CERT_MANAGER_CHART="oci://quay.io/jetstack/charts/cert-manager"
CERT_MANAGER_CHART_VERSION="v1.20.2"
PORKBUN_WEBHOOK_GROUP="acme.flowernode.com"
PORKBUN_WEBHOOK_APISERVICE="v1alpha1.${PORKBUN_WEBHOOK_GROUP}"
PORKBUN_WEBHOOK_VERSION="porkbun-webhook-0.1.5"
PORKBUN_WEBHOOK_URL="https://github.com/mdonoughe/porkbun-webhook/archive/refs/tags/${PORKBUN_WEBHOOK_VERSION}.tar.gz"
PORKBUN_WEBHOOK_ARCHIVE="${SCRIPT_DIR}/porkbun-webhook.tar.gz"
PORKBUN_WEBHOOK_DIR="${SCRIPT_DIR}/porkbun-webhook"
PORKBUN_WEBHOOK_CHART="${PORKBUN_WEBHOOK_DIR}/deploy/porkbun-webhook"
PORKBUN_WEBHOOK_RBAC="${SCRIPT_DIR}/porkbun-rbac.yaml"
SECRET="${SCRIPT_DIR}/secret.yaml"
MANIFEST="${SCRIPT_DIR}/deploy.yaml"

if [ ! -f "${SECRET}" ]; then
  echo "Missing ${SECRET}. Decrypt it or create it with the Porkbun API fields first." >&2
  exit 1
fi

echo "==> Installing/upgrading cert-manager ${CERT_MANAGER_CHART_VERSION}..."
helm upgrade --install "${CERT_MANAGER_RELEASE}" "${CERT_MANAGER_CHART}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CERT_MANAGER_CHART_VERSION}" \
  --set crds.enabled=true \
  --set replicaCount=2 \
  --set webhook.replicaCount=2 \
  --wait --timeout 10m

echo "==> Waiting for cert-manager webhook to be ready..."
kubectl -n "${NAMESPACE}" rollout status deployment/cert-manager-webhook --timeout=120s

if [ ! -d "${PORKBUN_WEBHOOK_CHART}" ]; then
  echo "==> Downloading Porkbun DNS-01 webhook ${PORKBUN_WEBHOOK_VERSION}..."
  curl -fL "${PORKBUN_WEBHOOK_URL}" -o "${PORKBUN_WEBHOOK_ARCHIVE}"
  rm -rf "${PORKBUN_WEBHOOK_DIR}"
  mkdir -p "${PORKBUN_WEBHOOK_DIR}"
  tar -xzf "${PORKBUN_WEBHOOK_ARCHIVE}" -C "${PORKBUN_WEBHOOK_DIR}" --strip-components=1
fi

echo "==> Installing/upgrading Porkbun DNS-01 webhook..."
helm upgrade --install porkbun-webhook "${PORKBUN_WEBHOOK_CHART}" \
  --namespace "${NAMESPACE}" \
  --set "groupName=${PORKBUN_WEBHOOK_GROUP}" \
  --wait --timeout 5m

echo "==> Applying Porkbun webhook RBAC..."
kubectl apply -f "${PORKBUN_WEBHOOK_RBAC}"

if ! kubectl get apiservice "${PORKBUN_WEBHOOK_APISERVICE}" >/dev/null 2>&1; then
  echo "Missing Porkbun DNS-01 webhook APIService ${PORKBUN_WEBHOOK_APISERVICE}." >&2
  echo "Check the Porkbun webhook Helm release before deploying app certificates." >&2
  exit 1
fi

echo "==> Applying Porkbun DNS secret, ClusterIssuer, and Flowernode Certificate..."
kubectl apply -f "${SECRET}"
kubectl apply -f "${MANIFEST}"

echo "==> cert-manager deployed successfully!"
kubectl -n "${NAMESPACE}" get pods
kubectl get clusterissuer letsencrypt-porkbun
kubectl -n "${NAMESPACE}" get certificate flowernode-com
