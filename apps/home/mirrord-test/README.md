# mirrord-test

Test app for mirrord - hooks local process into remote pod context (DNS, env, traffic).

## Files

| File             | Description                    |
| ---------------- | ------------------------------ |
| `k8s/test.yaml`  | Namespace, Deployment, Service |
| `.mirrord.json`  | mirrord config                 |
| `app/`           | Python app + Dockerfile        |

## Notes

- Image must be built and imported to nodes manually (`imagePullPolicy: Never`)
- Deploys 2 replicas of `podinfo` in `mirrord-demo` namespace

## Deploy

```bash
kubectl apply -f k8s/test.yaml
mirrord exec --config-file .mirrord.json python3 app/main.py
```
