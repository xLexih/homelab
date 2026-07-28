#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="cert-manager"
CERT_MANAGER_RELEASE="cert-manager"

echo "==> Deleting cert-manager Certificate, ClusterIssuer, and Porkbun secret..."
kubectl -n "${NAMESPACE}" delete certificate flowernode-com --ignore-not-found || true
kubectl delete clusterissuer letsencrypt-porkbun --ignore-not-found || true
kubectl -n "${NAMESPACE}" delete rolebinding porkbun-webhook-api-secret-reader --ignore-not-found || true
kubectl -n "${NAMESPACE}" delete role porkbun-api-secret-reader --ignore-not-found || true
kubectl -n "${NAMESPACE}" delete secret porkbun-api-secret --ignore-not-found || true

echo "==> Uninstalling cert-manager..."
helm uninstall "${CERT_MANAGER_RELEASE}" --namespace "${NAMESPACE}" || true

echo "==> Deleting cert-manager namespace..."
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "==> cert-manager uninstalled successfully!"
