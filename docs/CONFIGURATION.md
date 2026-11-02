# Describing a cluster

Every setting `cluster.nix` accepts is listed with a description in
`lib/options.nix`. This page covers the parts that need more than a line.

## Layout

```text
clusters/<name>/cluster.nix      nodes, roles, addresses
clusters/<name>/secrets/         admin.pub, k3s-token.age, hosts/<node>/{ssh-key,wireguard}.{age,pub}
lib/options.nix                  every setting cluster.nix accepts, with descriptions
lib/default.nix                  validation and per-node system assembly
lib/cli.nix                      the per-cluster command
modules/                         NixOS modules: base, network, k3s, cilium, network-policy, loadbalancer, storage, gpu, vm, lxc
tests/                           a VM test cluster, its throwaway keys, and the test script
```

The flake turns `clusters/home` into `nixosConfigurations.home-<node>` for
every node and `packages.home` for the command (`nix run .#home`).

## Roles

| role      | effect |
| --------- | ------ |
| `server`  | k3s control plane and etcd member. Use 1, 3 or 5. |
| `storage` | keeps Longhorn replicas on `/data`. Longhorn is installed once any node has this role; otherwise volumes use k3s local-path. |
| `gpu`     | NVIDIA driver and container runtime; the device plugin is installed cluster-wide. |
| (none)    | k3s agent. Every node, servers included, runs workloads. |

## Tags and labels

A node's `tags` and its roles become node labels `tag/<name>=true`, so a
workload can promise where it runs before a node exists:

```yaml
nodeSelector:
  tag/home: "true"   # or tag/gpu, tag/storage, tag/server
```

`labels` sets any other label as key = value; `tag/` keys belong to `tags`.
k3s applies node labels only when a node registers, so `switch` also sets
them on the running node, and removes the ones that an earlier `switch` set
and `cluster.nix` no longer has (the node annotation `cluster.nix/labels`
lists them). Labels set by hand with `kubectl label` stay.

## Example

`clusters/home/cluster.nix`: one server that also holds the Longhorn replicas
and the GPU, and a range of LAN addresses for LoadBalancer services:

```nix
{
  k3sVersion = "1.36";
  stateVersion = "26.05";
  init = "master1";               # the server that created the cluster
  clusterId = 1;                  # Cilium identity, for ClusterMesh later
  loadBalancerIPs = ["192.168.2.150-192.168.2.160"];
  gpuSharing = 3;                 # up to 3 pods share the GPU (time-slicing)
  registry.address = "192.168.2.151"; # in-cluster image registry (see Registry)

  nodes = {
    master1 = {
      roles = ["server" "storage" "gpu"];
      wgIP = "10.100.0.1";
      address = "192.168.2.105/24";
      gateway = "192.168.2.1";
      disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      dataDisk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
    };
  };
}
```

The README's quick start lists every option a node takes.

Nodes at another site join over WireGuard: give them a different `location`
and a public `endpoint`. A node behind NAT with no endpoint works too; it
dials the others. `platform = "lxc"` targets an existing NixOS container whose
disks the Proxmox host manages; see [lxc.md](lxc.md).

Every node needs eBPF, because Cilium is the pod network and replaces
kube-proxy. VMs have it out of the box; LXC containers need the host setup in
[lxc.md](lxc.md).

Mistakes are caught before anything is deployed. Evaluation refuses an even
number of servers, overlapping address ranges, a storage node without a data
disk, load balancer addresses outside every LAN or on top of a node, and a
long list of similar slips.

## Load balancer addresses

`loadBalancerIPs` takes single addresses, ranges and CIDRs, as many as you
like. Each `type: LoadBalancer` service gets an address of its own, so several
services can listen on the same port. One node on that subnet answers ARP for
the address, and if it fails another takes over within a few seconds. Pin an
address, or let a TCP and a UDP service share one, with annotations:

```yaml
metadata:
  annotations:
    lbipam.cilium.io/ips: 192.168.2.153
    lbipam.cilium.io/sharing-key: dns   # the same key on both services
```

Pods see the client's real address. A connection arrives at the announcing
node, which hands it to a backend pod, possibly on another node, and that pod
replies to the client directly (direct server return). The reply leaves from
the backend's node, so a service whose address belongs to one location has to
keep its pods there (node affinity on `topology.kubernetes.io/zone=<location>`).
The alternative is `service.cilium.io/forwarding-mode: snat`, which works from
anywhere but hides the client address. A proxy inside the cluster, such as an
ingress controller or a game router, opens a new connection, so the address
only reaches the app behind it if the proxy passes it on with PROXY protocol
or `X-Forwarded-For`.

In a cluster spread over several locations, each with addresses on its own
LAN, a service chooses where its address comes from with the label
`topology.kubernetes.io/zone=<location>`.

With `bgp`, the nodes also advertise every LoadBalancer address to your
routers, each router peering with the nodes on its own subnet. Addresses
outside every LAN become possible then. Label a service `bgp=off` to keep it
out.

```nix
bgp = {
  asn = 65100;
  peers = [{address = "192.168.2.1"; asn = 65000;}];
};
```

Without `loadBalancerIPs`, services get the nodes' own addresses. NodePorts
listen on the WireGuard mesh only.

## Registry

`registry.address` runs an image registry in the cluster. Pods name their
images `registry.registry.svc.cluster.local:5000/<name>:<tag>` (`registry.host`,
built from `namespace` and `port`). Nodes don't resolve cluster DNS, so every
node's containerd mirrors that name to the LoadBalancer address. The registry
accepts connections from the nodes and from the pods of `clientNamespaces`
only. Everything else has a default:

```nix
registry = {
  address = "192.168.2.151"; # inside loadBalancerIPs
  # size = "20Gi";                                # Longhorn volume
  # image = "registry:3.0.0@sha256:6c5666b8…";    # pinned by digest
  # namespace = "registry";                       # also the Service name
  # port = 5000;
  # clientNamespaces = ["otrust"];               # e.g. a gateway with TLS
};
```

Nothing on the LAN can push directly. Push through the API server; docker
speaks plain HTTP to 127.0.0.1 without extra configuration:

```bash
kubectl -n registry port-forward svc/registry 5000 &
docker push 127.0.0.1:5000/<name>:<tag>
```

A gateway in `clientNamespaces` can also serve the registry over HTTPS. The
registry answers with relative `Location` URLs, so it works behind a proxy
that terminates TLS.

## Private registries

`registries` is written to every node as k3s'
[`registries.yaml`](https://docs.k3s.io/installation/private-registry):
mirrors, credentials and TLS settings for containerd, merged with the mirror
for `registry`. k3s restarts when the file changes, since containerd only
reads it at start.

## Network policy

Every namespace except `kube-system`, `kube-public`, `kube-node-lease` and
`longhorn-system` gets a NetworkPolicy named `default-deny`: its pods accept
no connections, not even through a LoadBalancer or from other namespaces, and
can open none except DNS lookups. A freshly deployed app starts, passes its
health checks, and stays unreachable until you allow its traffic.

Ship the rules an app needs next to its manifests:

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

The rules people forget are for the Kubernetes API (operators, controllers,
anything with a service account: allow egress to the servers' `wgIP` on port
6443), for traffic between namespaces (both sides need one), and for webhooks
the API server calls. Cilium's own `CiliumNetworkPolicy` works as well, and
there `toEntities: [kube-apiserver]` covers the API.

To leave a namespace open while you experiment, label it:

```bash
kubectl label namespace scratch default-deny=off    # removes the policy
kubectl label namespace scratch default-deny-       # puts it back
```

A small `default-deny` service on every server watches namespaces and applies
the change within a second or two. Deleting the policy by hand doesn't stick:
it returns the next time that service restarts. Use the label.

<div align="right">

Generated by Opus 5.5

</div>
