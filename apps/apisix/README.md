# apisix

HA ingress controller with etcd backend (2 replicas, DSR-enabled).

## Files

| File             | Description                                          |
| ---------------- | ---------------------------------------------------- |
| `values.yaml`    | Helm values - 3 replicas, etcd mode, LoadBalancer IP |
| `pdb.yaml`       | PodDisruptionBudgets + CiliumNetworkPolicies         |
| `dashboard.yaml` | APISix Dashboard resources                           |

## Notes

- VIP: `192.168.2.150` (kube-vip, `loadbalancer.home.enabled: "true"`)
- Helm chart: `apisix/apisix` v2.13.0

## Deploy

```bash
./deploy.sh
```
