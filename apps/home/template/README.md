# template

Skeleton for new cluster apps. Copy, edit `.env`, and deploy.

## Quick start

```bash
cp -r apps/home/template apps/home/my-app
cd apps/home/my-app
cp .env.example .env
# edit .env → set APP_NAME, APP_NAMESPACE, etc.

just dev        # local nginx on :8080 (unprivileged, non-root)
just deploy     # to k8s cluster (immediately shows purple hello-world)
```

## Commands

| Command           | Description                                         |
| ----------------- | --------------------------------------------------- |
| `just`            | list targets                                        |
| `just dev`        | docker compose up + tail logs                       |
| `just dev-down`   | docker compose down                                 |
| `just docker-build` | docker build -t $APP_IMAGE .                      |
| `just docker-push`  | docker push $APP_IMAGE                             |
| `just deploy`     | envsubst → kubectl apply -k → rollout status        |
| `just full-deploy` | build → push → deploy                              |
| `just status`     | get pods,svc in namespace                           |
| `just logs`       | tail pod logs                                       |
| `just remove`     | delete the entire namespace                         |

## .env reference

| Variable              | Required | Default        | Description                              |
| --------------------- | -------- | -------------- | ---------------------------------------- |
| `APP_NAME`            | yes      | `myapp`        | Used for k8s resource names, selectors   |
| `APP_NAMESPACE`       | no       | `$APP_NAME`    | Kubernetes namespace                     |
| `APP_IMAGE`           | no       | `nginx:alpine` | Container image (built from `docker/`)   |
| `APP_REPLICAS`        | no       | `1`            | Deployment replicas                      |
| `APP_ENABLE_OCTELIUM` | no       | `true`         | Set false to skip Octelium-specific CRDs |
| `APP_DOMAIN`          | no       | *(empty)*      | Set to expose via ApisixRoute            |
| `APP_STORAGE_SIZE`    | no       | *(empty)*      | Set (e.g. `10Gi`) to create a PVC        |
| `APP_STORAGE_CLASS`   | no       | *(empty)*      | Required if `APP_STORAGE_SIZE` is set    |

## Conditional resources

| Condition                          | Resources applied                              |
| ---------------------------------- | ---------------------------------------------- |
| always                             | namespace, deployment, service                 |
| `APP_STORAGE_SIZE` non-empty       | PVC                                            |
| `APP_ENABLE_OCTELIUM=true`         | CiliumNetworkPolicy                            |
| both `APP_ENABLE_OCTELIUM` + `APP_DOMAIN` | ApisixRoute                            |

## Conventions

- One namespace per app
- Labels: `app.kubernetes.io/name`
- Liveness + readiness probes on every workload
- Resource requests/limits on every container
- CiliumNetworkPolicy: ingress from Apisix only, egress unconstrained
- ApisixRoute for external exposure via Octelium ingress
