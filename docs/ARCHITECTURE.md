# Architecture

## Evaluation

`flake.nix` reads every directory in `clusters/`. For each one, `lib/default.nix`

1. type-checks `cluster.nix` against `lib/options.nix`,
2. applies the cross-field rules in `validate` and refuses to evaluate anything
   if one fails,
3. builds one NixOS system per node from `modules/` plus `vm.nix` or
   `lxc.nix` (`nodeModules`), passing the checked cluster and the node as
   module arguments,
4. builds the cluster command from `lib/cli.nix`.

`tests/` builds its VMs from the same `nodeModules`, so the VM test exercises
exactly what gets deployed apart from disks and boot loader.

Modules never look at other clusters, and outputs are prefixed with the
cluster name, so clusters are independent. The only shared inputs are the
pinned nixpkgs, disko and agenix.

Roles are plain module conditions: `storage.nix` is active on every node once
some node has `storage` (clients everywhere, replicas on storage nodes, the
chart on servers); `gpu.nix` installs the driver on `gpu` nodes and the device
plugin on servers; `k3s.nix` picks server or agent from `server`.
`loadbalancer.nix` follows `loadBalancerIPs` instead of a role.
`network-policy.nix` runs on servers.

## Network

```text
             LAN (SSH, WireGuard UDP; ARP for service addresses)
   +------------+------------+------------+
   |            |            |            |
 node A ------ node B ------ node C       each service address answered by one node
   \___________ wg0 full mesh ___________/
      k3s API, etcd, kubelet, flannel VXLAN
```

- Each node has a `wgIP` on `wg0`, a WireGuard full mesh. Peers in the same
  `location` connect over the LAN, others through `endpoint`. Each peer only
  routes its own /32. Endpoints given as DNS names are resolved again every
  5 minutes, so a changed public address heals by itself.
- k3s uses the WireGuard address as node IP, binds the API and supervisor to
  it and runs flannel VXLAN over `wg0`. Pod routes therefore need no
  per-node configuration and all cluster traffic is encrypted.
- kube-proxy (iptables), network policy (kube-router) and metrics-server are
  the components embedded in k3s. NodePorts only listen on the mesh.
- With `loadBalancerIPs`, MetalLB in layer 2 mode assigns LoadBalancer
  addresses. Each entry becomes an address pool plus an advertisement limited
  to the nodes whose `address` subnet contains it and to their LAN interface.
  Speakers elect one node per address, answer ARP from it and hand over when
  their memberlist (over `wg0`) loses that node. kube-proxy DNATs the traffic
  on arrival. Without `loadBalancerIPs`, k3s ServiceLB publishes services on
  the node addresses instead.
- The LAN firewall allows SSH and the WireGuard port. `wg0`, `cni0` and
  `flannel.1` are trusted. Service and hostPort traffic is DNATed before the
  input chain.

## Control plane

The `init` server starts etcd with `--cluster-init` (also for a single server,
so snapshots work and more servers can be added later). Every other node
joins through `api.<cluster>.internal`, which `/etc/hosts` maps to the
WireGuard addresses of the other servers, `init` first. k3s connects to the
first address that accepts a connection (it runs with Go's resolver, which
keeps that order; glibc would reorder by address prefix), and all servers carry
the name in their certificate. A server that is running but has not joined
yet still accepts the connection and then refuses to admit anyone, so it must
never come before a working one: that is why the order is fixed.
After joining, servers use the etcd member list and agents the k3s client load
balancer, which learns the current servers from the API. `--cluster-init` is
ignored once a node has etcd data, so `init` can be moved to any server that
has already joined.

Servers run with `--secrets-encryption` and a PodSecurity admission
configuration enforcing `baseline` (and warning about `restricted`) outside
`kube-system`, `longhorn-system` and `metallb-system`. Namespaces that need
privileged pods opt out with the label
`pod-security.kubernetes.io/enforce=privileged`.

Every other namespace gets the `default-deny` NetworkPolicy (see README):
each server runs a `default-deny` unit that watches namespaces through
`k3s kubectl` and applies or removes the policy. kube-router enforces it.

The k3s package is `k3s_<k3sVersion>` from the pinned nixpkgs, so only lock
updates change the patch release and only `cluster.nix` changes the minor
release. The kubelet keeps `reserved.server` or `reserved.agent` away from
pods (`system-reserved`); pods are confined to the rest, so a runaway workload
is evicted or OOM-killed before etcd and the API server run short.

## Add-ons

CoreDNS (replacing the single k3s replica), MetalLB, Longhorn and the NVIDIA
device plugin are Helm charts fetched at build time with pinned hashes and
written to every server's manifest directory. The k3s helm-controller installs
and upgrades them from whichever server is alive, and nothing is downloaded at
boot besides container images. The charts use `failurePolicy: abort`: a failed
upgrade stays failed for a human to look at instead of being uninstalled and
reinstalled. The charts' own manifest files must not be named like one of k3s'
bundled manifests (`coredns.yaml`, `traefik.yaml`, ...), which k3s writes on
every start even when the component is disabled.

CoreDNS runs two replicas that may never share a node; while the cluster has
one node the second waits. CoreDNS and the MetalLB controller leave a failed
node after 30 seconds instead of Kubernetes' 300, so name resolution and
address assignment recover within about a minute and a half.

Longhorn stores replicas on `/data` of storage nodes only
(`createDefaultDiskLabeledNodes`), keeps `min(3, storage nodes)` replicas and
deletes pods of a dead node so their volumes can attach elsewhere.

## Nodes

- VMs are partitioned by disko: EFI and LVM on `disk` (a 10G etcd volume and
  root), and `/data` on `dataDisk`. Each VM gets the etcd volume so it can
  become a server later.
- LXC containers get their kernel, modules and global kernel settings from
  the Proxmox host. A preflight unit checks them before k3s starts,
  kube-proxy leaves the global conntrack limit to the host, and new
  generations are activated by restarting the container (see `lxc.md`).
- Nodes carry no documentation, default packages or GUI; the Nix store is
  garbage-collected weekly (14 days).

## Identity and secrets

Each node has a managed SSH host key, generated by `secrets sync` and stored
encrypted for the admin keys. `install` places it on the node, it pins the
node in the generated `known_hosts`, and agenix uses it to decrypt the node's
secrets:

| file | readable by |
| --- | --- |
| `k3s-token.age` | admin, every node of the cluster |
| `etcd-s3.age` | admin, servers |
| `hosts/<node>/wireguard.age` | admin, that node |
| `hosts/<node>/ssh-key.age` | admin |

Only the `admin` user may log in over SSH, only with a key listed in
`admin.pub` (`~/.ssh/authorized_keys` is ignored and users are immutable); it
has passwordless sudo, which deployment needs. Root and passwords are
disabled. LXC consoles log in as `admin` automatically, since reaching them
requires control of the Proxmox host. Protect the admin private key with a
passphrase: it is root on every node.
