#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="octelium"
DOMAIN="flowernode.com"
BOOTSTRAP="${SCRIPT_DIR}/bootstrap"
SECRET="${SCRIPT_DIR}/secret.yaml"
MANIFEST="${SCRIPT_DIR}/deploy.yaml"
GATEWAY_UDP="${SCRIPT_DIR}/gateway-udp.yaml"
CERT_MANAGER_IMPORT="${SCRIPT_DIR}/cert-manager/import.sh"
CLI_DIR="${SCRIPT_DIR}/cli"
OCTELIUM_CLI_VERSION="0.35.0"
GATEWAY_PUBLIC_IP="${GATEWAY_PUBLIC_IP:-}"
GATEWAY_LOAD_BALANCER_IP="${GATEWAY_LOAD_BALANCER_IP:-192.168.2.150}"
OCTELIUM_CLI_BASE_URL="https://github.com/octelium/octelium/releases/download/v${OCTELIUM_CLI_VERSION}"
OCTELIUM="$(command -v octelium || true)"
OCTELIUMCTL="$(command -v octeliumctl || true)"
OCTOPS="$(command -v octops || true)"
MULTUS_VERSION="v4.2.4"
MULTUS_IMAGE="ghcr.io/k8snetworkplumbingwg/multus-cni:${MULTUS_VERSION}-thick"
MULTUS_MANIFEST="https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/${MULTUS_VERSION}/deployments/multus-daemonset-thick.yml"

if [ -z "${OCTELIUM}" ]; then
  OCTELIUM="${CLI_DIR}/octelium"
fi

if [ -z "${OCTELIUMCTL}" ]; then
  OCTELIUMCTL="${CLI_DIR}/octeliumctl"
fi

if [ -z "${OCTOPS}" ]; then
  OCTOPS="${CLI_DIR}/octops"
fi

if [ ! -x "${OCTELIUM}" ] || [ ! -x "${OCTELIUMCTL}" ] || [ ! -x "${OCTOPS}" ]; then
  echo "==> Downloading Octelium CLIs ${OCTELIUM_CLI_VERSION}..."
  mkdir -p "${CLI_DIR}"
  curl -fL "${OCTELIUM_CLI_BASE_URL}/octelium-linux-amd64.tar.gz" -o "${CLI_DIR}/octelium-linux-amd64.tar.gz"
  curl -fL "${OCTELIUM_CLI_BASE_URL}/octeliumctl-linux-amd64.tar.gz" -o "${CLI_DIR}/octeliumctl-linux-amd64.tar.gz"
  curl -fL "${OCTELIUM_CLI_BASE_URL}/octops-linux-amd64.tar.gz" -o "${CLI_DIR}/octops-linux-amd64.tar.gz"
  curl -fL "${OCTELIUM_CLI_BASE_URL}/SHA256SUMS" -o "${CLI_DIR}/SHA256SUMS"
  (
    cd "${CLI_DIR}"
    sha256sum -c --ignore-missing SHA256SUMS
    tar -xzf octelium-linux-amd64.tar.gz
    tar -xzf octeliumctl-linux-amd64.tar.gz
    tar -xzf octops-linux-amd64.tar.gz
    chmod +x octelium octeliumctl octops
  )
fi

echo "==> Applying Octelium pre-requisites (secrets, storage, network policy)..."
kubectl apply -f "${SECRET}"
kubectl apply -f "${MANIFEST}"

echo "==> Waiting for Octelium storage to be ready..."
kubectl -n octelium-bootstrap rollout status statefulset/octelium-postgres --timeout=120s
kubectl -n octelium-bootstrap rollout status statefulset/octelium-redis --timeout=120s

echo "==> Labeling Octelium nodes..."
kubectl label node master1 octelium.com/node-mode-controlplane= --overwrite
kubectl label node master2 octelium.com/node-mode-dataplane- --overwrite
kubectl label node master3 octelium.com/node-mode-dataplane= --overwrite
if [ -n "${GATEWAY_PUBLIC_IP}" ]; then
  kubectl annotate node master3 "octelium.com/override-gw-ip=${GATEWAY_PUBLIC_IP}" --overwrite
fi

echo "==> Installing/updating Multus ${MULTUS_VERSION}..."
kubectl apply -f "${MULTUS_MANIFEST}"
kubectl -n kube-system set image daemonset/kube-multus-ds \
  kube-multus="${MULTUS_IMAGE}" \
  install-multus-binary="${MULTUS_IMAGE}"
kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=120s

if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "==> Upgrading Octelium..."
  "${OCTOPS}" upgrade "${DOMAIN}" --wait
else
  echo "==> Installing Octelium..."
  "${OCTOPS}" init "${DOMAIN}" --bootstrap "${BOOTSTRAP}"
fi

echo "==> Enabling the local LoadBalancer for Octelium ingress..."
kubectl -n "${NAMESPACE}" label svc octelium-ingress-dataplane \
  loadbalancer.home.enabled=true \
  --overwrite
kubectl -n "${NAMESPACE}" annotate svc octelium-ingress-dataplane \
  io.cilium/lb-ipam-sharing-key=apisix-gateway \
  kube-vip.io/allow-shared-ip=apisix-gateway \
  --overwrite
kubectl -n "${NAMESPACE}" patch svc octelium-ingress-dataplane \
  --type merge \
  -p "{\"spec\":{\"loadBalancerIP\":\"${GATEWAY_LOAD_BALANCER_IP}\",\"externalTrafficPolicy\":\"Local\"}}"
kubectl apply -f "${GATEWAY_UDP}"

echo "==> Importing the shared public certificate into Octelium..."
"${CERT_MANAGER_IMPORT}"

echo "==> Octelium deployed successfully!"
kubectl -n "${NAMESPACE}" get pods,svc
