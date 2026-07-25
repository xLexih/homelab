# cert-manager

Cluster cert-manager deployment for shared certificate infrastructure.

## Files

| File           | Description                                            |
| -------------- | ------------------------------------------------------ |
| `deploy.sh`    | Installs cert-manager and applies the Porkbun issuer and certificate |
| `uninstall.sh` | Removes cert-manager app resources                      |
| `deploy.yaml`  | Let's Encrypt Porkbun `ClusterIssuer` and Flowernode `Certificate` |
| `porkbun-rbac.yaml` | Lets the Porkbun webhook read `porkbun-api-secret` |
| `secret.yaml`  | Porkbun API secret, ignored by Git                     |

## Conventions

- Namespace: `cert-manager`
- cert-manager chart version: `v1.20.2`
- cert-manager chart: `oci://quay.io/jetstack/charts/cert-manager`
- Porkbun webhook release: `porkbun-webhook-0.1.5`
- Porkbun webhook group and solver: `acme.flowernode.com`, `porkbun`
- ClusterIssuer: `letsencrypt-porkbun`
- Certificate: `cert-manager/flowernode-com`
- TLS Secret: `cert-manager/flowernode-com-tls`
- DNS names: `flowernode.com`, `*.flowernode.com`
- Porkbun Secret: `cert-manager/porkbun-api-secret`
- Porkbun Secret reader: `cert-manager/porkbun-api-secret-reader`

## Secrets

`secret.yaml` is ignored by Git. `.age` files are allowed.

`deploy.sh` downloads the pinned Porkbun webhook release into
`porkbun-webhook/`, installs its local Helm chart, applies local Secret-reader RBAC,
and checks for APIService `v1alpha1.acme.flowernode.com` before applying the
issuer and Flowernode certificate.

Docs:

- cert-manager Helm install: `https://cert-manager.io/docs/installation/helm/`
- DNS01 webhook solver: `https://cert-manager.io/docs/configuration/acme/dns01/webhook/`
- Porkbun webhook: `https://github.com/mdonoughe/porkbun-webhook`

Encrypt after editing:

```bash
age -R ../../secrets/admin.pub -o secret.yaml.age secret.yaml
```

Decrypt before deploying:

```bash
age -d -i ~/.ssh/k3s-admin -o secret.yaml secret.yaml.age
chmod 600 secret.yaml
```

## Install

Run from this directory.

```bash
age -d -i ~/.ssh/k3s-admin -o secret.yaml secret.yaml.age
chmod 600 secret.yaml
./deploy.sh
kubectl get apiservice v1alpha1.acme.flowernode.com
kubectl get clusterissuer letsencrypt-porkbun
kubectl -n cert-manager get certificate flowernode-com
kubectl -n cert-manager get secret flowernode-com-tls
```

## Uninstall

Run from this directory.

```bash
./uninstall.sh
```
