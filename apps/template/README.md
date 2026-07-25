# template

Skeleton for new cluster apps. Copy and replace `EXAMPLE` with your app name.

## Files

| File          | Description                                          |
| ------------- | ---------------------------------------------------- |
| `deploy.yaml` | Namespace, StorageClass, PVC, Service, NetworkPolicy |
| `deploy.sh`   | Applies manifests, prints pod and service status     |

## Conventions

- One namespace per app
- Longhorn StorageClass: `reclaimPolicy: Retain`, 2 replicas
- CiliumNetworkPolicy: ingress from the Octelium namespace only
- Labels: `app.kubernetes.io/name`

## Cilium And Host-Network Pods

`fromEndpoints` rules match Cilium endpoint identities, not Kubernetes pod
labels on host-network traffic. If an app has a node agent, gateway, or other
`hostNetwork: true` client that must call a Cilium-protected pod, allow the
right host identities explicitly with `fromEntities`, usually `host`,
`remote-node`, and sometimes `kube-apiserver`.

The failure pattern is DNS success followed by a TCP timeout from the
host-network pod, while normal pods can reach the same Service. Confirm it with
`cilium-dbg monitor --type drop`; look for `Policy denied` from a node IP to
the target pod or Service backend.

## Deploy

```bash
cp -r apps/template apps/my-app
sed -i 's/EXAMPLE/my-app/g' apps/my-app/deploy.yaml apps/my-app/deploy.sh
./apps/my-app/deploy.sh
```
