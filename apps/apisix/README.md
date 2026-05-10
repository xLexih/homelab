# APISix Ingress Controller

HA ingress controller with etcd backend (2 replicas, DSR-enabled).

## Prerequisites

- Cilium CNI deployed
- kube-vip running (for LoadBalancer IP)
- CiliumLoadBalancerIPPool for `home` location

## Deployment

```bash
# 1. Add Helm repository
helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update

# 2. Install APISix (creates namespace automatically)
helm upgrade --install apisix apisix/apisix \
  -n apisix --create-namespace \
  -f values.yaml \
  --version 2.13.0 \
  --atomic --history-max 3 \
  --timeout 10m

# 3. Apply PDBs and NetworkPolicies
kubectl apply -f pdb.yaml
```

## Files

| File          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `values.yaml` | Helm values - 3 replicas, etcd mode, LoadBalancer IP |
| `pdb.yaml`    | PodDisruptionBudgets + CiliumNetworkPolicies         |

## Verify

```bash
kubectl get pods -n apisix
kubectl get svc -n apisix
curl http://192.168.2.150
```

## LoadBalancer IP

VIP: `192.168.2.150` (managed by kube-vip via `loadbalancer.home.enabled: "true"` label)
