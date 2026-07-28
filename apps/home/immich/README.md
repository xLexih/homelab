# immich

Self-hosted photo/video management with GPU-accelerated machine learning.

## Files

| File          | Description                                               |
| ------------- | --------------------------------------------------------- |
| `deploy.yaml` | Namespace, StorageClass, PVCs, PostgreSQL, Service, Route |
| `deploy.sh`   | Orchestrates deploy order (DB first, then Helm)           |
| `values.yaml` | Helm values - server, ML with CUDA, Valkey cache          |

## Storage

- `immich-library`: 100Gi (photos/videos)
- `immich-db`: 10Gi (PostgreSQL)
- Valkey cache: 2Gi
- ML model cache: 20Gi

## Access

- HTTP: `gallery.flowernode.com` via APISix (WebSocket enabled)
- SVG uploads blocked at ingress

## Deploy

```bash
./deploy.sh
```
