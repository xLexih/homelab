#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOMAIN="flowernode.com"
SOURCE_NAMESPACE="cert-manager"
SOURCE_CERTIFICATE="flowernode-com"
SECRET_NAME="flowernode-com-tls"
CERT_DIR="${APP_DIR}/cert"
CERT="${CERT_DIR}/${DOMAIN}.crt"
KEY="${CERT_DIR}/${DOMAIN}.key"
OCTOPS="$(command -v octops || true)"

if [ -z "${OCTOPS}" ]; then
  OCTOPS="${APP_DIR}/cli/octops"
fi

mkdir -p "${CERT_DIR}"

echo "==> Waiting for cert-manager certificate..."
kubectl -n "${SOURCE_NAMESPACE}" wait certificate/"${SOURCE_CERTIFICATE}" --for=condition=Ready --timeout=10m

echo "==> Exporting cert-manager TLS Secret..."
kubectl -n "${SOURCE_NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CERT}"
kubectl -n "${SOURCE_NAMESPACE}" get secret "${SECRET_NAME}" -o jsonpath='{.data.tls\.key}' | base64 -d > "${KEY}"
chmod 600 "${KEY}"

echo "==> Importing certificate into Octelium..."
OCTELIUM_INSECURE_TLS=true "${OCTOPS}" certificate "${DOMAIN}" \
  --cert "${CERT}" \
  --key "${KEY}"

echo "==> Octelium certificate installed!"
