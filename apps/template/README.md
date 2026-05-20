# template

Skeleton for new cluster apps. Copy and replace `EXAMPLE` with your app name.

## Files

| File          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `deploy.yaml` | Namespace, StorageClass, PVC, Service, NetworkPolicy |
| `deploy.sh`   | Applies manifests, prints pod status                 |

## Conventions

- One namespace per app
- Longhorn StorageClass: `reclaimPolicy: Retain`, 2 replicas
- CiliumNetworkPolicy: ingress from apisix only
- Labels: `app.kubernetes.io/name`

## Deploy

```bash
cp -r apps/template apps/my-app
sed -i 's/EXAMPLE/my-app/g' apps/my-app/deploy.yaml apps/my-app/deploy.sh
./apps/my-app/deploy.sh
```
