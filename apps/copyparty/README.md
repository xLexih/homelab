# copyparty

Self-hosted file sharing server with SFTP support.

## Files

| File          | Description                                                            |
| ------------- | ---------------------------------------------------------------------- |
| `deploy.yaml` | Namespace, StorageClass, PVCs, ConfigMap, Deployment, Service, NetPol  |
| `route.yaml`  | ApisixRoute CRDs for HTTP and SFTP traffic                             |

## Storage

- `copyparty-files`: 100Gi (file storage)
- `copyparty-config`: 5Gi (history/metadata)

## Access

- HTTP: `file.flowernode.com` via APISix
- SFTP: port 2222 via APISix stream proxy

## Deploy

```bash
kubectl apply -f deploy.yaml
kubectl apply -f route.yaml
```
