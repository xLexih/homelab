# NixOS K3s Clusters

Declarative NixOS configuration for independent K3s clusters on Proxmox VMs
and NixOS LXC containers.

The active project manages host configuration and core cluster services:

- K3s with embedded etcd;
- WireGuard node mesh;
- Cilium networking;
- kube-vip load-balancer addresses;
- Longhorn storage;
- an optional internal Docker registry;
- NVIDIA GPU support.

Application manifests are intentionally outside this project. The old `apps/`
tree is legacy and is not part of the supported architecture.

## Requirements

- Nix with flakes enabled;
- `direnv` for the optional development shell;
- Proxmox VMs or pre-installed NixOS LXC containers;
- SSH access to each initial target;
- an Ed25519 administrative key at `~/.ssh/k3s-admin`.

The flake is pinned to NixOS 26.05. Each cluster also sets
`cluster.stateVersion = "26.05"` explicitly.

## Repository layout

```text
.
├── config/                 Cluster definitions
├── lib/                    Cluster factory, helpers, and validation
├── modules/                Reusable NixOS and core Kubernetes modules
├── scripts/                Deployment, image, secret, and kubeconfig tools
├── secrets/                Age-encrypted node and cluster secrets
├── docs/                   Architecture and operational notes
├── flake.nix               Outputs, development shell, and checks
└── flake.lock              Reproducible input revisions
```

## Initial setup

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin -N ""
cp ~/.ssh/k3s-admin.pub secrets/admin.pub

nix run .#secrets-home -- init
nix run .#secrets-teddysmp -- init
nix flake check
```

`secrets rekey` re-encrypts the K3s token, WireGuard keys, and encrypted SSH
host-key backups for the current recipients.

## VM deployment

`deploy init` is destructive because it uses Disko and `nixos-anywhere`.
Confirm the node definition and target before you run it.

An initial machine does not yet use the repository-managed SSH host identity.
Use `--insecure-bootstrap` only for this transition:

```bash
nix run .#deploy-home -- init master1 \
  --insecure-bootstrap \
  -u root \
  -i ~/.ssh/current-installer-key
```

After activation, direct root SSH is disabled. Normal deployments use the
`admin` account and verify the tracked host key:

```bash
nix run .#deploy-home -- rebuild master1 -i ~/.ssh/k3s-admin
nix run .#deploy-home -- all -i ~/.ssh/k3s-admin
```

`deploy all` is sequential. It deploys the init node last and stops if a node
is unreachable, its host key does not match, or K3s is not active.
When an older generation does not yet trust `admin` as a Nix user, the deploy
tool copies the first closure through a temporary passwordless-sudo transport
and removes it after the copy. For VMs, this transition stages the generation
without a live switch; reboot the VM to activate it. Later deployments switch
normally.

## LXC deployment

LXC nodes must already run NixOS. Proxmox owns their kernel, root filesystem,
devices, and storage mounts. The first rebuild installs the managed SSH host
identity and stages a boot generation:

```bash
nix run .#deploy-teddysmp -- rebuild teddysmp \
  --insecure-bootstrap \
  -u root \
  -H <initial-address> \
  -i ~/.ssh/current-lxc-key
```

Reboot the container from Proxmox after the command completes. Future
deployments use the configured `admin` user and managed host key:

```bash
nix run .#deploy-teddysmp -- rebuild teddysmp -i ~/.ssh/k3s-admin
```

The Proxmox host must provide cgroup v2 delegation, bpffs, `/dev/kmsg`,
`/dev/net/tun`, and the kernel modules needed by K3s and Cilium. Longhorn LXC
nodes also need a dedicated `/data` mount and `iscsi_tcp`. See
[docs/LXC.conf](docs/LXC.conf) for the current host profile.

## Interactive shell and console

SSH and local console sessions use a shared Bash setup with completion,
searchable history, compact Kubernetes aliases, and a single-line pastel prompt. The
prompt uses `∴` for success, `×<code>` for failure, and `λ` for input. Set
`NO_COLOR=1` to disable color.

All terminal definitions are installed, including xterm, tmux, Kitty, foot,
and WezTerm support. LXC nodes start a getty on `/dev/console`, so the Proxmox
console opens an `admin` session without a password prompt. VM consoles keep
normal authentication.

`comma` is installed on every node and uses the flake-managed nix-index
database. It can run tools that are not part of the permanent system:

```bash
, dig example.com
```

## Commands

Every command is scoped to one cluster.

| Command | Purpose |
| --- | --- |
| `nix run .#deploy-home -- rebuild <node> [options]` | Rebuild one home node |
| `nix run .#deploy-home -- all [options]` | Rebuild all home nodes sequentially |
| `nix run .#deploy-home -- rollback <node> [options]` | Roll back one node |
| `nix run .#secrets-home -- init` | Create missing encrypted secrets |
| `nix run .#secrets-home -- rekey` | Update all secret recipients |
| `nix run .#image-home -- add <archive> [node\|all] [key]` | Import an image on one or all nodes |
| `nix run .#config-home -- <node> [key]` | Write `~/.kube/home.yaml` |

The kubeconfig command does not replace `~/.kube/config`. Start the printed
SSH tunnel, then use the scoped file:

```bash
KUBECONFIG=~/.kube/home.yaml kubectl get nodes
```

## Development and checks

```bash
direnv allow
nix fmt
nix flake check --show-trace
```

The flake check evaluates every NixOS configuration, checks Nix formatting,
runs Statix and Deadnix, tests invalid cluster definitions, and runs ShellCheck
against the generated command-line tools. GitHub Actions runs the same check
for pushes and pull requests.

## Adding a cluster

1. Copy the nearest file under `config/example/`.
2. Give the cluster and every node a globally unique name.
3. Set the explicit `stateVersion`.
4. Add one `mkCluster` call in `flake.nix`.
5. Merge its outputs with `mergeUnique`.
6. Generate its secrets and run `nix flake check`.

Cluster validation rejects invalid locations, missing node networks, duplicate
or overlapping pod ranges, network-range overlap, invalid load-balancer pools,
even-sized HA control planes, and unsupported storage combinations.
