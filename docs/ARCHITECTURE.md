# Architecture

## Scope

This repository configures NixOS hosts and the Kubernetes components needed by
each cluster. Application deployment is outside its scope. The removed
`apps/` tree is legacy.

Two independent clusters are currently produced:

```text
home
├── master1: init, control plane, worker, storage, NVIDIA GPU
├── master2: control plane, worker, storage
└── master3: control plane, worker, storage

teddysmp
└── teddysmp: LXC init, control plane, worker
```

The clusters do not share K3s tokens, WireGuard meshes, service ranges, pod
ranges, or kubeconfigs.

## Evaluation model

`flake.nix` calls `lib/mkCluster.nix` for each cluster definition:

1. Evaluate the typed cluster options.
2. Run cross-field validation from `lib/helpers.nix`.
3. Generate one `nixosSystem` for each node.
4. Generate cluster-scoped command-line packages.
5. Reject duplicate output names when cluster outputs are merged.

The flake lock pins Nixpkgs, Disko, Agenix, and the Nix index. The NixOS state
version is explicit in each cluster and does not follow Nixpkgs automatically.

## Node networking

Each cluster uses a full-mesh WireGuard interface named `wg0`. A peer permits
the peer's WireGuard address and pod CIDR. Explicit routes send remote pod
traffic through that peer.

Endpoint selection is location-aware:

1. Nodes in the same location use the peer LAN address when available.
2. Other locations use `wgEndpoint`, then `endpoint`, then the cluster domain.
3. `endpointPort` represents a public forwarded WireGuard port.
4. `wgPort` remains the node's local listen port.

K3s advertises and binds to the node WireGuard address. Control-plane and pod
traffic therefore use the encrypted mesh.

The LAN firewall exposes only the configured SSH and WireGuard ports, plus TCP
80 and 443 when the cluster load balancer is enabled. The Kubernetes API is
not exposed on the LAN firewall.

## K3s control plane

The init server starts K3s with `--cluster-init`. Other servers join through
the init server's WireGuard address. K3s uses embedded etcd for control-plane
state.

Non-init masters run HAProxy on `127.0.0.1:6443`. It balances local Kubernetes
client traffic across all master WireGuard addresses. The init node uses its
local K3s API directly.

Automated multi-node deployment is sequential. Non-init nodes are deployed
first and the init node is deployed last. Deployment stops when SSH identity
verification or the post-deployment K3s health check fails.

## Cilium

K3s disables Flannel, kube-proxy, and the built-in network policy controller.
Cilium provides Kubernetes IPAM, native routing over WireGuard pod routes,
kube-proxy replacement, BPF masquerading, load-balancer data paths, and
network policy.

The operator runs with two replicas on an HA cluster and one replica on a
single-node cluster. A periodic host service waits for Cilium's NAT chain
before it adds the WireGuard masquerade compatibility rule.

## Load balancers

When enabled, kube-vip runs on control-plane nodes and announces service
addresses on the LAN with ARP. Cilium load-balancer pools are generated per
location and select services by this label:

```text
loadbalancer.<location>.enabled=true
```

Leader election uses a 15-second lease, 10-second renewal deadline, and
2-second retry period. Actual failover time must be measured during a failure
test; it is bounded by lease expiry.

## Core component reconciliation

The init master deploys Cilium, kube-vip, Longhorn, the optional registry, and
the NVIDIA device plugin with Helm systemd services.

Each service waits for the API and Helm repository setup, then runs
`helm upgrade --install` with atomic rollback, cleanup, workload waits, and
timeouts. There are no persistent success marker files. A failed rollout does
not become a permanent false success.

## Storage

The home cluster uses Longhorn with two replicas and dedicated `/data`
filesystems. TeddySMP uses the K3s local-path provisioner.

Disk selection and layout are explicit in node configuration. VM installation
uses Disko. LXC storage is mounted by Proxmox and `storage.disks` must remain
empty.

## Registry

The optional Docker Distribution registry is a ClusterIP service. Longhorn
clusters use an RWX storage class; a single local-storage node uses RWO.

The registry remains plain HTTP inside the cluster. A Cilium policy restricts
registry ingress to cluster nodes and pods in the registry namespace. Image
deletion in the optional UI is disabled unless `registry.allowDelete = true`.

## Identity and secrets

Agenix decrypts node secrets with the managed Ed25519 SSH host identity.
Encrypted data includes the K3s token, WireGuard keys, and recoverable managed
SSH host keys.

Normal management commands use a generated `known_hosts` file derived from
the tracked host public keys. An explicit `--insecure-bootstrap` mode exists
only for the first transition to the managed identity.

Direct root SSH is disabled after activation. The `admin` account has the
tracked administrative key and passwordless sudo for declarative deployment.

## Validation boundaries

Evaluation rejects invalid init roles, addresses, locations, network ranges,
load-balancer pools, storage combinations, LXC disks, even-sized HA control
planes, and duplicate node names across clusters. Runtime preflight services
check LXC cgroups, bpffs, device access, and storage mounts.
