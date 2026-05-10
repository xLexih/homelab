# Mirrord Test

Test deployment for [mirrord](https://mirrord.dev/) - hooks local app into pod context (DNS, files, env, traffic).

## Prerequisites

- Build and export the image locally:
  ```bash
  docker build -t podinfo:latest ./app
  docker save podinfo:latest | gzip > podinfo.tar.gz
  ```

- Import to all nodes:
  ```bash
  for node in 192.168.2.105 192.168.2.106 192.168.2.107; do
    scp podinfo.tar.gz root@$node:/tmp/
    ssh root@$node "gunzip -c /tmp/podinfo.tar.gz | k3s ctr images import -"
  done
  ```

## Deployment

```bash
kubectl apply -f k8s/test.yaml
```

## Test Mirrord

```bash
# Install mirrord
nix shell nixpkgs#mirrord

# Run local app with pod context
mirrord exec --config-file .mirrord.json python3 app/main.py
```

## Verify

```bash
kubectl run tmp-shell --rm -it --image=curlimages/curl -n mirrord-demo --restart=Never -- sh
curl -s http://podinfo
```

## Cleanup

```bash
kubectl delete namespace mirrord-demo
```
