# octelium

Octelium deployment scaffold for this cluster.

## Files

| File                         | Description                                             |
| ---------------------------- | ------------------------------------------------------- |
| `deploy.sh`                  | Installs or upgrades Octelium                           |
| `uninstall.sh`               | Deletes Octelium and its cluster prerequisites          |
| `deploy.yaml`                | Bootstrap storage and Cilium host-network policy        |
| `gateway-udp.yaml`           | LoadBalancer Service for Octelium gateway UDP traffic   |
| `secret.yaml`                | PostgreSQL and Redis password Secrets, ignored by Git   |
| `bootstrap`                  | Octelium `octops init` bootstrap config                 |
| `dex-octelium.yaml`          | Octelium resources for Dex browser login                |
| `dex-values.yaml`            | Dex Helm values with local login secret, ignored        |
| `dex-secret.txt`             | Dex local admin login note, ignored by Git              |
| `cert-manager/import.sh`     | Imports the shared cert-manager TLS Secret into Octelium |

## Conventions

- Domain: `flowernode.com`
- Public cert DNS names: `flowernode.com`, `*.flowernode.com`
- Control-plane node: `master1`
- Dataplane node: `master3`
- Ingress LoadBalancer IP: `192.168.2.150`
- Gateway UDP LoadBalancer IP: `192.168.2.150`
- LoadBalancer selector label: `loadbalancer.home.enabled=true`
- Multus version: `v4.2.4`
- Multus image: `ghcr.io/k8snetworkplumbingwg/multus-cni:v4.2.4-thick`
- Octelium CLI version: `0.35.0`
- Dex chart version: `0.24.1`
- Required cert-manager certificate: `cert-manager/flowernode-com`
- Public certificate Secret: `cert-manager/flowernode-com-tls`
- Bootstrap config: `bootstrap`
- Kubernetes manifests: `deploy.yaml`
- Storage secrets: `secret.yaml`
- Exported certificate work dir: `certs/`

## Requirements

- `kubectl`
- `age`
- `curl`, `tar`, and `sha256sum`
- `apps/cert-manager` deployed first
- DNS for `flowernode.com` and `*.flowernode.com`
- Cilium with `cni.exclusive=false`
- Multus CNI

`deploy.sh` imports the shared public certificate after Octelium is installed.
The shared cert-manager installation, Porkbun webhook, Porkbun Secret,
`ClusterIssuer/letsencrypt-porkbun`, and `Certificate/flowernode-com` live in
`../cert-manager`.

Commands in this README assume the current directory is `apps/octelium`.

## Secrets

Ignored local files:

- `secret.yaml`
- `dex-values.yaml`
- `dex-secret.txt`

Keep the plaintext files local. Store the `.age` files if you want the encrypted
copy in Git.

Encrypt after editing:

```bash
age -R ../../secrets/admin.pub -o secret.yaml.age secret.yaml
```

Decrypt before deploying:

```bash
age -d -i ~/.ssh/k3s-admin -o secret.yaml secret.yaml.age
chmod 600 secret.yaml
```

## Notes

`octelium-bootstrap` is only this app's storage namespace. It can be removed
only if Octelium's PostgreSQL and Redis endpoints are provided somewhere else.

Octelium serves a private-CA certificate after bootstrap. Replace it by
importing the shared public certificate from `cert-manager/flowernode-com-tls`
that covers `flowernode.com` and `*.flowernode.com`.

`octelium-gwagent` runs with `hostNetwork: true`. If it crash-loops with:

```text
octeliumC unavailable ... dial tcp <octelium-rscserver ClusterIP>:8080: i/o timeout
```

check Cilium drops on the node running `octelium-rscserver`:

```bash
kubectl -n kube-system exec <cilium-pod-on-rscserver-node> -- cilium-dbg monitor --type drop
```

The useful signal is:

```text
drop (Policy denied) ... <node-ip>:<port> -> <rscserver-pod-ip>:8080 tcp SYN
```

Keep the Cilium host-network policy in `deploy.yaml` unless upstream Octelium
fixes the generated policy for host-networked gateway agents.

Browser login is backed by Dex at `https://idp.flowernode.com/dex`. Use
`https://flowernode.com/login`; the local admin secret is in `dex-secret.txt`.

Client tunnel access from outside the LAN needs the public router to forward
gateway UDP traffic to the Octelium VIP `192.168.2.150`:

- UDP `53820` for the default WireGuard tunnel.
- UDP `8443` if using the experimental QUIC tunnel.

Keep Octelium dataplane scheduling limited to `master3` while using this single
shared VIP. Multiple Gateway resources behind the same UDP VIP can make clients
select one gateway while Kubernetes forwards packets to another.

## Install

Run from this directory.

```bash
# Fetch kubeconfig.
nix run ../..#get-kubeconfig -- master1 ~/.ssh/k3s-admin

# Deploy the shared cert-manager app first.
cd ../cert-manager
age -d -i ~/.ssh/k3s-admin -o secret.yaml secret.yaml.age
chmod 600 secret.yaml
./deploy.sh
cd ../octelium

# Decrypt Octelium local secrets.
age -d -i ~/.ssh/k3s-admin -o secret.yaml secret.yaml.age
chmod 600 secret.yaml

# Install or upgrade Octelium.
# Missing Octelium CLIs are downloaded into cli/.
# The public Let's Encrypt certificate is imported at the end.
./deploy.sh

# Verify.
kubectl -n octelium get pods,svc
curl -I https://flowernode.com/
openssl s_client \
  -servername flowernode.com \
  -connect flowernode.com:443 </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -dates
```

## Uninstall

Run from this directory.

```bash
./uninstall.sh
```
