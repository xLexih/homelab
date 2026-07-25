# octelium certificate

Octelium resources that consume the shared cert-manager app.

Commands assume the current directory is `apps/octelium`.
The top-level `./deploy.sh` calls this import helper.

## Files

| File          | Description                                             |
| ------------- | ------------------------------------------------------- |
| `import.sh`   | Imports `cert-manager/flowernode-com-tls` into Octelium |

## Requirements

- `kubectl`
- `apps/cert-manager` deployed first
- `cert-manager/flowernode-com` is Ready

## Import

```bash
./cert-manager/import.sh
```
