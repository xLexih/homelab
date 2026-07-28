# Verification

## Local checks

```bash
nix fmt
nix flake check --show-trace
nix build --no-link \
  .#deploy-home .#image-home .#secrets-home .#config-home \
  .#deploy-teddysmp .#image-teddysmp .#secrets-teddysmp .#config-teddysmp
```

Confirm the effective release and state version:

```bash
nix eval --raw .#nixosConfigurations.master1.config.system.nixos.release
nix eval --raw .#nixosConfigurations.master1.config.system.stateVersion
```

Both values must be `26.05`.

## CLI smoke tests

```bash
nix run .#deploy-home -- --help
nix run .#image-home -- --help
nix run .#secrets-home -- --help
nix run .#config-home -- --help
```

The home deployment order must be `master2 -> master3 -> master1`.

## Deployment verification

Deploy one non-init node first:

```bash
nix run .#deploy-home -- rebuild master2 -i ~/.ssh/k3s-admin
```

The command must verify the managed host key, complete the rebuild, and confirm
that `k3s.service` is active.

Then verify the cluster:

```bash
nix run .#config-home -- master1 ~/.ssh/k3s-admin
# Start the tunnel printed by the command in another terminal.
KUBECONFIG=~/.kube/home.yaml kubectl get nodes -o wide
KUBECONFIG=~/.kube/home.yaml kubectl get pods -A
KUBECONFIG=~/.kube/home.yaml cilium status --wait
```

All three home nodes must be `Ready`. TeddySMP is a separate cluster and must
not appear in this output.

## Failure tests

Perform these tests during a maintenance window:

1. Stop kube-vip on its current leader and measure service-address failover.
2. Reboot one non-init home master and confirm etcd quorum and API access.
3. Change a Helm value, rebuild the init node, and confirm reconciliation.
4. Stop Cilium during boot and confirm the WireGuard NAT service retries.
5. Import one image with target `all` and confirm it exists on every home node.

## LXC verification

After staging and rebooting TeddySMP:

```bash
nix run .#config-teddysmp -- teddysmp ~/.ssh/k3s-admin
# Start the printed tunnel.
KUBECONFIG=~/.kube/teddysmp.yaml kubectl get nodes -o wide
```

The cluster must contain only the `teddysmp` node:

```bash
ssh -i ~/.ssh/k3s-admin admin@teddysmp.com \
  'systemctl is-active wireguard-wg0 k3s; sudo wg show'
```
