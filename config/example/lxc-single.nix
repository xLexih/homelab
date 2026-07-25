# Single-node LXC cluster on a VPS (e.g. TeddySMP).
# - 1 LXC container with master + worker
# - k3s local-path provisioner (no replicas)
# - Docker Distribution registry with local-path StorageClass
#   (useful for push/pull on a VPS without Longhorn)
# - DHCP networking with public endpoint
# - Separate CIDR block reserved for future ClusterMesh
#
# Prerequisites:
# - Proxmox installed on VPS (or any LXC host)
# - Privileged LXC container with: nesting=1, keyctl=1
# - Host kernel modules: wireguard, geneve, overlay, tun, veth
#
# Copy to config/<name>.nix and add to flake.nix via mkCluster.
{...}: {
  cluster = {
    name = "lxc-single";

    # local-path — the simplest option for a single node.
    # Docker registry below targets this StorageClass.
    storageBackend = "local";

    etcdSnapshotRetention = 30;

    # Docker distribution registry. On single-node clusters with
    # "local" storage, the registry PVC binds to k3s local-path
    # StorageClass (RWX is skipped, only one replica is safe).
    registry = {
      type = "docker";
      storageSize = "10Gi";
      replicas = 1;
      enableUI = false;
      http = true;
    };

    # CIDRs reserved for this cluster. All independent clusters
    # should use unique ranges to avoid conflicts when connecting
    # via Cilium ClusterMesh later.
    # Convention: even offset from home (10.42, 10.43, 10.100).
    network = {
      serviceCIDR = "10.44.0.0/16";
      podCIDR = "10.45.0.0/16";
      wgCIDR = "10.101.0.0/24";
      wgPort = 51820;
      wgMTU = 1440;
      domain = null;
      # LXC containers use eth0, not ens18 (ens18 is VM only).
      lanInterface = "eth0";
      nameservers = ["1.1.1.1" "8.8.8.8"];
      wgKeepalive = 25;
      apiServerPort = 6443;
    };

    loadBalancer.enable = false;

    locations.vps = {description = "VPS LXC";};

    coredns.replicas = 1;

    nodes = {
      node1 = {
        platform = "lxc";
        roles = ["master" "worker"];
        location = "vps";
        init = true;

        network = {
          wgIP = "10.101.0.1";
          # VPS providers typically assign IPs via DHCP
          useDHCP = true;
          # Public DNS name — required for DHCP without cluster domain
          endpoint = "node1.example.com";
          endpointPort = 51820;
          sshPort = 22;
          sshUser = "root";
        };

        podCIDR = "10.45.0.0/24";

        gpu.enable = false;

        # LXC: host owns / and /data. No disk config possible.
        storage.disks = [];
      };
    };
  };
}
