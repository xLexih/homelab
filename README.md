# NixOS k3s clusters

Every directory under `clusters/` is one k3s cluster: a `cluster.nix` describing
its nodes and a `secrets/` directory with age-encrypted keys. The flake picks
new directories up automatically and produces, per cluster:

- `nixosConfigurations.<cluster>-<node>` for every node,
- `packages.<cluster>`, a command-line tool to install and operate it.

A node's `roles` decide what it runs:

| role      | effect |
| --------- | ------ |
| `server`  | k3s control plane and etcd member. Use 1, 3 or 5. |
| `storage` | keeps Longhorn replicas on `/data`. Longhorn is installed once any node has this role; otherwise volumes use k3s local-path. |
| `gpu`     | NVIDIA driver and container runtime; the device plugin is installed cluster-wide. |
| (none)    | k3s agent. Every node, servers included, runs workloads. |

The design, the network layout and the security model are described in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Layout

```text
clusters/<name>/cluster.nix      nodes, roles, addresses
clusters/<name>/secrets/         admin.pub, k3s-token.age, hosts/<node>/{ssh-key,wireguard}.{age,pub}
lib/options.nix                  every setting cluster.nix accepts, with descriptions
lib/default.nix                  validation and per-node system assembly
lib/cli.nix                      the per-cluster command
modules/                         NixOS modules: base, network, k3s, storage, gpu, vm, lxc
```

## Defining a cluster

A single machine:

```nix
# clusters/lab/cluster.nix
{
  stateVersion = "26.05";
  nodes.lab1 = {
    roles = ["server"];
    wgIP = "10.100.0.1";
    address = "192.168.1.10/24";
    gateway = "192.168.1.1";
    disk = "/dev/sda";
  };
}
```

Three servers with replicated storage, two plain workers and a floating LAN
address for LoadBalancer services:

```nix
{
  stateVersion = "26.05";
  init = "cp1"; # the server that bootstraps etcd; never change it afterwards
  vip = "192.168.1.50";

  nodes = let
    node = n: roles: {
      inherit roles;
      wgIP = "10.100.0.${toString n}";
      address = "192.168.1.${toString (10 + n)}/24";
      gateway = "192.168.1.1";
      disk = "/dev/sda";
    } // (if builtins.elem "storage" roles then {dataDisk = "/dev/sdb";} else {});
  in {
    cp1 = node 1 ["server" "storage"];
    cp2 = node 2 ["server" "storage"];
    cp3 = node 3 ["server" "storage"];
    w1 = node 4 [];
    w2 = node 5 ["gpu"];
  };
}
```

Nodes elsewhere join over WireGuard. Give them a different `location` and a
public `endpoint`; nodes behind NAT without an endpoint are dialled by the
others. `platform = "lxc"` targets an existing NixOS container whose disks the
Proxmox host manages (see [docs/lxc.md](docs/lxc.md)). Evaluation rejects
inconsistent definitions (even server counts, overlapping ranges, storage
nodes without a data disk, a VIP outside every node's subnet, and so on).

## First installation

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin          # use a passphrase and ssh-agent
mkdir -p clusters/lab/secrets
cp ~/.ssh/k3s-admin.pub clusters/lab/secrets/admin.pub
nix run .#lab -- secrets sync                       # host keys, WireGuard keys, k3s token
nix flake check

# init server first, then the rest; a VM's disks are erased after confirmation
nix run .#lab -- install cp1 root@<installer-ip>
nix run .#lab -- install cp2 root@<installer-ip>
```

`install` boots VMs into NixOS with `nixos-anywhere`, putting the node's
managed SSH host key in place so it can decrypt its secrets on first boot. For
an LXC node it copies the host key into the running container and stages the
new system; restart the container from Proxmox afterwards.

## Operating

| command | |
| --- | --- |
| `nix run .#lab -- switch all` | deploy every node: init, other servers, agents; stops at the first node that is not `Ready` |
| `nix run .#lab -- switch cp2 w1` | deploy some nodes |
| `nix run .#lab -- rollback cp2` | back to the previous generation |
| `nix run .#lab -- ssh cp2` | SSH with the pinned host key |
| `nix run .#lab -- kubeconfig` | write `~/.kube/lab.yaml` and print the SSH tunnel command for the API |
| `nix run .#lab -- image app.tar.gz` | import an image archive on every node |
| `nix run .#lab -- secrets sync` | create keys for new nodes and re-encrypt all secrets for the current nodes |
| `nix run .#lab -- secrets edit etcd-s3.age` | edit an encrypted file |

Secrets are decrypted with `$AGE_IDENTITY` (default `~/.ssh/k3s-admin`);
`admin.pub` may list several keys. The command must run inside this repository
and stages generated files with `git add`, because the flake only sees tracked
files.

Adding a node: add it to `cluster.nix`, run `secrets sync`, `install` it, then
`switch all` so every peer learns its WireGuard key. Removing one: drain and
delete it in Kubernetes, remove it from `cluster.nix`, `secrets sync`,
`switch all`, then delete its `secrets/hosts/<node>` directory.

## Backups

Every server keeps etcd snapshots (twice a day, 14 retained) in
`/var/lib/rancher/k3s/server/db/snapshots`. For an off-site copy set
`etcdS3 = { endpoint = "…"; bucket = "…"; };` and store the credentials with
`secrets edit etcd-s3.age`:

```text
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

Restore follows the k3s documentation (`k3s server --cluster-reset
--cluster-reset-restore-path=…` on the init server). Longhorn volumes need
their own backup target, configured in Longhorn.

## Checks

```bash
nix fmt
nix flake check
```

`flake check` evaluates every node, runs alejandra, deadnix and statix,
ShellChecks each cluster command, and confirms that a set of broken cluster
definitions is rejected. CI runs the same on every push.

Upgrading k3s or NixOS means bumping `flake.lock` and running `switch all`.
Chart versions and hashes are pinned in `modules/k3s.nix`, `storage.nix` and
`gpu.nix`; move Longhorn one minor version at a time.
