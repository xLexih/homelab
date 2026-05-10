# copyparty

Self-hosted file sharing server with SFTP support.

## Prerequisites

- Longhorn storage deployed
- APISix ingress controller deployed (for routes)

## Deployment

```bash
# 1. Deploy the application (namespace, storage, deployment, service)
kubectl apply -f deploy.yaml

# 2. Create APISix routes (after APISix is deployed)
kubectl apply -f route.yaml
```

## Files

| File | Description |
|------|-------------|
| `deploy.yaml` | Namespace, StorageClass, PVCs, ConfigMap, Deployment, Services, PDB, NetworkPolicy |
| `route.yaml` | ApisixRoute CRDs for HTTP and SFTP traffic |

## Access

- **HTTP**: Via APISix ingress (route: `/*`)
- **SFTP**: Via APISix stream proxy (port 2222)

## Storage

- `copyparty-files`: 150Gi (x2 replicas = 300Gi total)
- `copyparty-config`: 5Gi

Uses custom StorageClass `longhorn-copyparty` with `reclaimPolicy: Retain`.

## Verify

```bash
kubectl get pods -n copyparty
kubectl get pvc -n copyparty
```
