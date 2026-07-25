# Minimal single-node cluster (VM).
# - 1 VM node with master + worker roles
# - k3s local-path provisioner (no replication, no dependency)
# - Embedded registry (Spegel): P2P image distribution, zero storage
# - No LoadBalancer (kube-vip disabled)
# - CoreDNS with 1 replica
#
# Use cases: dev/test, single VPS, learning.
# Copy to config/<name>.nix and add to flake.nix via mkCluster.
{...}: {
  cluster = {
    name = "single";

    # Storage backend (no replicas, single point of failure).
    # "local"    — k3s local-path provisioner. Simple, zero deps.
    # "longhorn" — distributed HA block storage. Needs 3+ nodes
    #              with "storage" role. Adds ~1GB RAM overhead/node.
    storageBackend = "local";

    # Number of daily etcd snapshots to retain. Older are pruned.
    etcdSnapshotRetention = 30;

    # In-cluster registry.
    # "none"   — no registry, images from external registries only
    # "k3s"    — k3s embedded P2P registry (Spegel). No storage.
    # "docker" — Dedicated Docker Distribution with persistent storage.
    #            On single-node, uses k3s local-path StorageClass.
    #            Enables push/pull workflow for custom images.
    registry = {
      type = "k3s";
    };

    # Network configuration — plan CIDRs to avoid overlaps if you
    # intend to connect clusters via Cilium ClusterMesh later.
    network = {
      # Kubernetes service ClusterIP range
      serviceCIDR = "10.43.0.0/16";
      # Kubernetes pod IP range (assigned by Cilium)
      podCIDR = "10.42.0.0/16";
      # WireGuard overlay network — each node gets one IP
      wgCIDR = "10.100.0.0/24";
      # WireGuard UDP listen port
      wgPort = 51820;
      # MTU = 1500 - 60 (WireGuard overhead). Reduce if nesting
      # tunnels (e.g. Cilium Geneve adds ~50 more bytes → 1390).
      wgMTU = 1440;
      # Cluster domain: used to construct node FQDN endpoints
      # ("<name>.<cluster>.<domain>") when no explicit endpoint is
      # set. null = no domain resolution.
      domain = null;
      # Primary LAN interface.
      # VMs (Proxmox/qemu) — "ens18"  (virtio, default)
      # LXC containers     — "eth0"   (veth pair to host)
      lanInterface = "ens18";
      # DNS nameservers for the cluster nodes
      nameservers = ["1.1.1.1" "8.8.8.8"];
      # WG persistent keepalive for NAT traversal (seconds).
      # 0 = disabled. Needed when peers are behind NAT/firewalls.
      wgKeepalive = 25;
      # Kubernetes API server port (nodePort for kubeconfig)
      apiServerPort = 6443;
    };

    # LoadBalancer (kube-vip + Cilium IP pools).
    # Disabled for single-node. Enable with pools for HA clusters
    # that need stable VIPs (bare-metal, on-prem).
    loadBalancer.enabled = false;

    # Locations — referenced by nodes.<name>.location.
    # At least one required. Multiple locations enable the
    # multi-datacenter WireGuard mesh pattern.
    locations.home = {
      description = "Home Lab";
    };

    # CoreDNS — number of replicas. 1 for single-node, 2+ for HA.
    coredns.replicas = 1;

    # Node definitions.
    nodes = {
      node1 = {
        # Platform:
        #   "vm"  — EFI-booted machine, disko-managed disk layout
        #   "lxc" — pre-existing LXC container rebuilt in place;
        #           Proxmox owns kernel, devices, storage mounts
        platform = "vm";

        # Roles:
        #   "master"  — control plane (etcd + kube-apiserver + scheduler)
        #   "worker"  — runs application pods
        #   "storage" — Longhorn disk provider (ignored for "local")
        roles = ["master" "worker"];

        # Must match a key in cluster.locations
        location = "home";

        # Exactly one master must be init (bootstraps etcd).
        init = true;

        # Per-node network — WireGuard IP is always required.
        network = {
          # Unique WG IP from cluster.network.wgCIDR
          wgIP = "10.100.0.1";

          # Static IP config (useDHCP defaults to false)
          lanIP = "192.168.2.101";
          gateway = "192.168.2.1";
          lanPrefixLength = 24;

          # Alternative: DHCP (common for cloud VPS, LXC).
          # set useDHCP = true;
          # Then set endpoint (DNS name) — required so other
          # nodes can reach this node via WireGuard:
          # endpoint = "node1.example.com";

          # SSH access
          sshPort = 22;
          sshUser = "nixos";
        };

        # Per-node pod CIDR — must be a /24 unique across all nodes
        # (Cilium assigns one /24 per node by default).
        podCIDR = "10.42.0.0/24";

        # GPU passthrough (NVIDIA only, Proxmox PCI passthrough).
        gpu = {
          enable = false;
          vendor = "nvidia";
          pciId = "";
          model = null;
          memory = null;
        };

        # Disk layout (for platform = "vm" only; LXC uses []).
        # At least one disk must have the "system" role.
        # Each role can appear at most once across all disks.
        storage = {
          disks = [
            {
              device = "/dev/sda";
              # Roles:
              #   "system" — EFI boot + root partition (required)
              #   "etcd"   — dedicated etcd partition (SSD recommended)
              #   "data"   — Longhorn data partition (only for "longhorn")
              roles = ["system"];
              # Partition sizes (defaults apply if omitted)
              sizes = {
                system = "50G";
                # etcd = "30G";
                # data = "100%";
              };
            }
          ];
        };
      };
    };
  };
}
