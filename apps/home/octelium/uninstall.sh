#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="octelium"
BOOTSTRAP_NAMESPACE="octelium-bootstrap"
DOMAIN="flowernode.com"
OCTOPS="$(command -v octops || true)"
MULTUS_VERSION="v4.2.4"

if [ -z "${OCTOPS}" ]; then
  OCTOPS="${SCRIPT_DIR}/cli/octops"
fi

echo "==> Uninstalling Octelium..."
if [ -x "${OCTOPS}" ]; then
  "${OCTOPS}" uninstall "${DOMAIN}" || true
fi
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "==> Deleting Octelium bootstrap storage..."
kubectl delete namespace "${BOOTSTRAP_NAMESPACE}" --ignore-not-found

echo "==> Deleting Octelium Cilium policy..."
kubectl delete ciliumclusterwidenetworkpolicy octelium-rscserver-hostnetwork --ignore-not-found || true

echo "==> Removing Octelium node labels..."
kubectl label node master1 octelium.com/node-mode-controlplane- --overwrite || true
kubectl label node master2 octelium.com/node-mode-dataplane- --overwrite || true
kubectl label node master3 octelium.com/node-mode-dataplane- --overwrite || true

echo "==> Removing Multus ${MULTUS_VERSION} Kubernetes resources..."
kubectl -n kube-system delete daemonset kube-multus-ds --ignore-not-found
kubectl -n kube-system delete configmap multus-daemon-config --ignore-not-found
kubectl -n kube-system delete serviceaccount multus --ignore-not-found
kubectl delete clusterrolebinding multus --ignore-not-found || true
kubectl delete clusterrole multus --ignore-not-found || true
kubectl delete crd network-attachment-definitions.k8s.cni.cncf.io --ignore-not-found || true

echo "==> Octelium uninstalled successfully!"
kubectl get namespace "${NAMESPACE}" "${BOOTSTRAP_NAMESPACE}" --ignore-not-found
