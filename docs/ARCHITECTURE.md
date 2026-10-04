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
`cilium.nix`, `network-policy.nix` and `loadbalancer.nix` (when
`loadBalancerIPs` is set) run on servers.

## Network

```text
             LAN (SSH, WireGuard UDP; ARP and BGP for service addresses)
   +------------+------------+------------+
   |            |            |            |
 node A ------ node B ------ node C       each service address answered by one node
   \___________ wg0 full mesh ___________/
      k3s API, etcd, kubelet, Cilium Geneve tunnels
```

- Each node has a `wgIP` on `wg0`, a WireGuard full mesh. Peers in the same
  `location` connect over the LAN, others through `endpoint`. Each peer only
  routes its own /32. Endpoints given as DNS names are resolved again every
  5 minutes, so a changed public address heals by itself.
- k3s uses the WireGuard address as node IP and binds the API and supervisor
  to it. Its own flannel, kube-proxy and kube-router are off; Cilium is the
  CNI. Pods reach each other through Geneve tunnels between node IPs, so the
  packets cross `wg0` encrypted, WireGuard never needs to know pod CIDRs, and
  pod addresses arrive unchanged on the other node. Cilium's MTU follows
  `network.wgMTU`.
- Cilium replaces kube-proxy in eBPF. Its agents reach the API through every
  server's `wgIP` (`k8s.apiServerURLs`), since no Service works before they
  run. NodePorts only listen on `wg0`.
- With `loadBalancerIPs`, Cilium LB IPAM assigns LoadBalancer addresses. The
  entries are grouped by the location of the nodes whose `address` subnet
  contains them; each group becomes an address pool plus an L2 announcement
  policy limited to those nodes and their LAN interface. One node per service
  holds a lease and answers ARP; another takes over within 3 to 7 seconds of
  it failing. With several groups, a service picks one with the label
  `topology.kubernetes.io/zone`. Entries outside every LAN form a pool only
  BGP can reach. Without `loadBalancerIPs`, Cilium node IPAM gives services
  the node addresses.
- External traffic to a service uses direct server return: the announcing
  node passes each connection to a backend over Geneve with the service
  address in a Geneve option, and the backend's node answers the client
  itself. Pods therefore see client addresses. Annotating a service
  `service.cilium.io/forwarding-mode: snat` turns this off for it.
- With `bgp`, Cilium's BGP control plane peers each router with the nodes on
  its subnet and advertises every LoadBalancer address (`bgp=off` on a service
  excludes it).
- The LAN firewall allows SSH and the WireGuard port. `wg0`, Cilium's devices
  and the pods' `lxc*` veths are trusted. Service traffic is handled by eBPF
  on the LAN interface before the input chain.

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
`kube-system` and `longhorn-system`. Namespaces that need
privileged pods opt out with the label
`pod-security.kubernetes.io/enforce=privileged`.

Every other namespace gets the `default-deny` NetworkPolicy (see
[CONFIGURATION.md](CONFIGURATION.md#network-policy)):
each server runs a `default-deny` unit that watches namespaces through
`k3s kubectl` and applies or removes the policy. Cilium enforces it; its
`policyCIDRMatchMode=nodes` lets `ipBlock` rules select node addresses.

The k3s package is `k3s_<k3sVersion>` from the pinned nixpkgs, so only lock
updates change the patch release and only `cluster.nix` changes the minor
release. The kubelet keeps `reserved.server` or `reserved.agent` away from
pods (`system-reserved`); pods are confined to the rest, so a runaway workload
is evicted or OOM-killed before etcd and the API server run short.

## Add-ons

Cilium, CoreDNS (replacing the single k3s replica), Longhorn and the NVIDIA
device plugin are Helm charts fetched at build time with pinned hashes and
written to every server's manifest directory. The k3s helm-controller installs
and upgrades them from whichever server is alive, and nothing is downloaded at
boot besides container images. Cilium is a bootstrap chart: its installer Job
runs on a server's host network against `127.0.0.1:6443`, which k3s serves
next to the `wgIP`, since there is no pod network before it. The charts use
`failurePolicy: abort`: a failed upgrade stays failed for a human to look at
instead of being uninstalled and reinstalled, and `status` in the cluster
command shows it. The charts' own manifest files must not be named like one
of k3s' bundled manifests (`coredns.yaml`, `traefik.yaml`, ...), which k3s
writes on every start even when the component is disabled.

Before k3s starts, servers delete links in the manifest directory that point
into the Nix store but are no longer in the configuration; the NixOS k3s
module leaves them behind, and k3s would keep applying them. Removing a chart
from the configuration therefore stops it from being reapplied but does not
uninstall it: `kubectl delete helmchart <name> -n kube-system` does.

CoreDNS runs two replicas that may never share a node; while the cluster has
one node the second waits. CoreDNS leaves a failed node after 30 seconds
instead of Kubernetes' 300, so name resolution recovers within about a minute
and a half.

Longhorn stores replicas on `/data` of storage nodes only
(`createDefaultDiskLabeledNodes`), keeps `min(3, storage nodes)` replicas and
deletes pods of a dead node so their volumes can attach elsewhere.

## Nodes

- VMs are partitioned by disko: EFI and LVM on `disk` (a 10G etcd volume and
  root), and `/data` on `dataDisk`. Each VM gets the etcd volume so it can
  become a server later.
- LXC containers get their kernel, modules and global kernel settings from
  the Proxmox host. A preflight unit checks them (including the BPF
  filesystem Cilium needs) before k3s starts, and new generations are
  activated by restarting the container (see `lxc.md`).
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

<div align="right">

Generated by Opus 5.5

</div>
