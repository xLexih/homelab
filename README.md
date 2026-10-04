<div align="center">

# NixOS k3s clusters

**Declarative NixOS configuration for independent k3s clusters**

[![NixOS](https://img.shields.io/badge/NixOS-26.05-5277C3?logo=nixos&logoColor=white)](https://nixos.org)
[![K3s](https://img.shields.io/badge/K3s-1.35-ffc61c?logo=k3s)](https://k3s.io)
[![WireGuard](https://img.shields.io/badge/WireGuard-mesh-88171a?logo=wireguard&logoColor=white)](https://www.wireguard.com)
[![MetalLB](https://img.shields.io/badge/MetalLB-0.16.1-aa0000)](https://metallb.io)
[![Longhorn](https://img.shields.io/badge/Longhorn-1.12.1-431439)](https://longhorn.io)

</div>

---

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
modules/                         NixOS modules: base, network, k3s, network-policy, loadbalancer, storage, gpu, vm, lxc
tests/                           a VM test cluster, its throwaway keys, and the test script
```

## Defining a cluster

A single machine:

```nix
# clusters/lab/cluster.nix
{
  stateVersion = "26.05";
  k3sVersion = "1.35";
  nodes.lab1 = {
    roles = ["server"];
    wgIP = "10.100.0.1";
    address = "192.168.1.10/24";
    gateway = "192.168.1.1";
    disk = "/dev/sda";
  };
}
```

Three servers with replicated storage, two plain workers and a pool of LAN
addresses for LoadBalancer services:

```nix
{
  stateVersion = "26.05";
  k3sVersion = "1.35";
  init = "cp1"; # the server that creates the cluster
  loadBalancerIPs = ["192.168.1.50-192.168.1.59"];

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
nodes without a data disk, load balancer addresses outside the LAN or on top
of a node's address, and so on).

## Load balancer addresses

`loadBalancerIPs` accepts single addresses, ranges and CIDRs, as many as you
like. With it set, MetalLB gives every `type: LoadBalancer` service its own
address; one node on that subnet answers for it and another takes over within
seconds if the node fails. Several services can therefore use the same port.
Pin an address or share one between services with annotations:

```yaml
metadata:
  annotations:
    metallb.io/loadBalancerIPs: 192.168.1.53
    metallb.io/allow-shared-ip: dns   # same key on the TCP and UDP service
```

Without `loadBalancerIPs` the cluster uses k3s ServiceLB instead, which needs
no extra pods but publishes services on every node's own address, so each
port can be used by one service only.

## Network policy

> [!WARNING]
> Workloads are closed by default. Every namespace except `kube-system`,
> `kube-public`, `kube-node-lease`, `longhorn-system` and `metallb-system`
> gets a NetworkPolicy named `default-deny`: its pods accept no connections,
> not even from a LoadBalancer or from other namespaces, and can open none
> except DNS lookups. A freshly deployed app therefore starts, passes its
> health checks, and is unreachable until you allow its traffic.

Allow what each app needs next to its manifests, for example:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: web, namespace: web}
spec:
  podSelector: {matchLabels: {app: web}}
  policyTypes: [Ingress, Egress]
  ingress:
    - ports: [{port: 8080}]                     # anyone, e.g. through its LoadBalancer
  egress:
    - to: [{podSelector: {matchLabels: {app: db}}}]
      ports: [{port: 5432}]                     # its database in the same namespace
    - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [10.0.0.0/8]}}]
      ports: [{port: 443}]                      # HTTPS to the internet
```

Things that need an explicit allow and are easy to forget: the Kubernetes API
(operators, controllers, anything using a service account; allow egress to
the servers' `wgIP` on port 6443), traffic between namespaces (both sides need
a rule), and webhooks called by the API server.

To leave a namespace open, e.g. while experimenting, label it:

```bash
kubectl label namespace scratch default-deny=off    # removes the policy
kubectl label namespace scratch default-deny-       # restores it
```

Every server runs a small `default-deny` service that watches namespaces and
adds or removes the policy within a second or two of a change. Deleting the
policy by hand only lasts until that service next re-lists (at the latest after
a k3s restart or about 30 minutes); use the label instead.

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
an LXC node it copies the host key into the running container, stages the new
system and restarts the container.

## Operating

| command | |
| --- | --- |
| `nix run .#lab -- switch all` | deploy every node: init, other servers, agents; stops at the first node that is not `Ready` |
| `nix run .#lab -- switch cp2 w1` | deploy some nodes |
| `nix run .#lab -- rollback cp2` | back to the previous generation |
| `nix run .#lab -- remove cp2` | move data and workloads off a node and delete it from Kubernetes and etcd |
| `nix run .#lab -- ssh cp2` | SSH with the pinned host key |
| `nix run .#lab -- kubeconfig` | write `~/.kube/lab.yaml` and print the SSH tunnel command for the API |
| `nix run .#lab -- image app.tar.gz` | import an image archive on every node |
| `nix run .#lab -- secrets sync` | create keys for new nodes and re-encrypt all secrets for the current nodes |
| `nix run .#lab -- secrets edit etcd-s3.age` | edit an encrypted file |

Secrets are decrypted with `$AGE_IDENTITY` (default `~/.ssh/k3s-admin`);
`admin.pub` may list several keys. The command must run inside this repository
and stages generated files with `git add`, because the flake only sees tracked
files.

## Adding and removing nodes

Adding a node, any role, any time:

```bash
$EDITOR clusters/lab/cluster.nix          # add the node
nix run .#lab -- secrets sync             # its keys; the token is re-encrypted for it
nix run .#lab -- install w3 root@<ip>
nix run .#lab -- switch all               # every node learns the new WireGuard peer
```

The new node joins through the `init` server, or through the other servers in
alphabetical order if `init` does not accept connections, so `init` does not
need to be up. Until `switch all` has reached the other
nodes it cannot talk to them and stays NotReady; k3s keeps retrying.
Existing nodes are not restarted: adding a WireGuard peer starts one extra
unit, and MetalLB, Longhorn and CoreDNS settings that depend on the node count
are updated by the helm-controller.

Removing a node:

```bash
nix run .#lab -- remove w3                # cordon, move Longhorn replicas, drain, delete
$EDITOR clusters/lab/cluster.nix          # delete the node (and move `init` if it was that one)
nix run .#lab -- secrets sync             # deletes its keys, drops it as a recipient
nix run .#lab -- switch all
```

`remove` waits until Longhorn has rebuilt the node's replicas elsewhere, which
is impossible while a volume has as many replicas as there are storage nodes:
add a storage node first or lower that volume's replica count. For a node that
is already dead it skips draining and just deletes it; deleting a server's
node object also removes its etcd member. On a live node `remove` stops k3s
only until the next boot, because NixOS keeps `/etc` read-only: power the node
off (or reinstall it) before it reboots, or it rejoins while the others still
list it as a WireGuard peer. After `switch all` it can no longer reach them.

Server counts stay odd in `cluster.nix`. Growing from 1 to 3 or 3 to 5 means
adding both servers to the file and installing them; they join through the
existing servers, so the order does not matter.
Changing a node's roles in place works for `storage` and `gpu`; to turn an
agent into a server or back, remove it and add it again.

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
nix flake check                                  # everything below; the VM test takes about 5 minutes
nix build .#checks.x86_64-linux.vm -L            # only the VM test, with its log
```

`flake check` evaluates every node, runs alejandra, deadnix and statix,
ShellChecks each cluster command, and confirms that a set of broken cluster
definitions is rejected. It also runs `tests/`: four VMs built from the real
modules plus a deployer VM running the cluster command. The test checks that
a node joins while the `init` server is down, that `ssh`, `kubeconfig`,
`image` and `remove` work (including removing a dead server's etcd member),
that a LoadBalancer address is assigned and reachable, and that the
default-deny policy blocks traffic until an app's own policy allows it. It
needs KVM and about 6 GB of free memory. CI runs the same on every push.
`install`, `switch` and `rollback` are not covered: they need a real
installer and a network connection.

## Upgrading

Updates are manual. `nix flake update`, then `nix flake check`, then
`switch all`. Patch releases of k3s arrive with the lock update. The
Kubernetes minor version only changes when you raise `k3sVersion` in a
cluster's `cluster.nix`, one minor version at a time; `switch all` upgrades
the servers before the agents, as k3s requires.

Chart versions and hashes are pinned in `modules/k3s.nix`, `loadbalancer.nix`,
`storage.nix` and `gpu.nix`; move Longhorn one minor version at a time. The VM
test runs without internet access, so when a chart's image changes, update
the matching image digest in `tests/default.nix` as well
(`nix run nixpkgs#nix-prefetch-docker -- --image-name … --image-tag …`).

<div align="right">

Written by spark-1.3

</div>
