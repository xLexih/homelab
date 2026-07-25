# Multi-location cluster (home + cloud VPS).
# - 3 masters at home (same LAN, low latency)
# - 1 LXC worker at a cloud VPS (WAN, behind NAT)
# - Longhorn (replicas on home nodes only; remote is compute-only)
# - kube-vip LoadBalancer on home LAN only
# - WireGuard full mesh across locations with NAT traversal
#
# NOTE: This is the LEGACY pattern. The current recommended approach
# is separate independent clusters (see config/home.nix and
# config/teddysmp.nix) connected via Cilium ClusterMesh. This file
# exists for reference and for cases where a single cluster must
# span WAN boundaries.
#
# Requirements:
# - UDP port forwarding from public IP to each home master
# - Public DNS A record for the cloud worker
# - Stable WireGuard port for each node behind the same public IP
{...}: {
  cluster = {
    name = "multi-location";

    storageBackend = "longhorn";

    registry = {
      type = "docker";
      storageSize = "20Gi";
      replicas = 2;
      enableUI = true;
      http = true;
    };

    network = {
      serviceCIDR = "10.43.0.0/16";
      podCIDR = "10.42.0.0/16";
      wgCIDR = "10.100.0.0/24";
      wgPort = 51820;
      domain = null;
      lanInterface = "ens18";
    };

    loadBalancer = {
      enabled = true;
      pools.home = {
        start = "192.168.2.150";
        stop = "192.168.2.160";
      };
    };

    # Two locations — home LAN and cloud VPS.
    locations = {
      home = {description = "Home Lab";};
      cloud = {description = "Cloud VPS";};
    };

    coredns.replicas = 2;

    nodes = {
      node1 = {
        roles = ["master" "worker" "storage"];
        location = "home";
        init = true;
        network = {
          wgIP = "10.100.0.1";
          lanIP = "192.168.2.101";
          gateway = "192.168.2.1";
          # Public domain for WG reachable from other locations.
          # If multiple masters share one domain, use distinct ports.
          wgEndpoint = "home.example.com";
          endpointPort = 51821;
          sshUser = "nixos";
        };
        podCIDR = "10.42.0.0/24";
        storage = {
          disks = [
            {device = "/dev/sdb"; roles = ["system" "etcd"]; sizes = {system = "40G"; etcd = "100%FREE";};}
            {device = "/dev/sda"; roles = ["data"];}
          ];
        };
      };

      node2 = {
        roles = ["master" "worker" "storage"];
        location = "home";
        network = {
          wgIP = "10.100.0.2";
          lanIP = "192.168.2.102";
          gateway = "192.168.2.1";
          wgEndpoint = "home.example.com";
          endpointPort = 51822;
          sshUser = "nixos";
        };
        podCIDR = "10.42.1.0/24";
        storage = {
          disks = [
            {device = "/dev/sdb"; roles = ["system" "etcd"]; sizes = {system = "40G"; etcd = "100%FREE";};}
            {device = "/dev/sda"; roles = ["data"];}
          ];
        };
      };

      node3 = {
        roles = ["master" "worker" "storage"];
        location = "home";
        network = {
          wgIP = "10.100.0.3";
          lanIP = "192.168.2.103";
          gateway = "192.168.2.1";
          wgEndpoint = "home.example.com";
          endpointPort = 51823;
          sshUser = "nixos";
        };
        podCIDR = "10.42.2.0/24";
        storage = {
          disks = [
            {device = "/dev/sdb"; roles = ["system" "etcd"]; sizes = {system = "40G"; etcd = "100%FREE";};}
            {device = "/dev/sda"; roles = ["data"];}
          ];
        };
      };

      # Remote LXC worker at cloud VPS — compute only, no storage.
      cloud-worker = {
        platform = "lxc";
        roles = ["worker"];
        location = "cloud";

        network = {
          wgIP = "10.100.0.10";
          # Cloud VPS typically uses DHCP
          useDHCP = true;
          # Public DNS A record pointing to the VPS IP.
          # Required when useDHCP = true (no fixed LAN IP).
          endpoint = "cloud-worker.example.com";
          # Default WG port — only 1 node behind this IP
          endpointPort = 51820;
          sshUser = "root";
        };

        podCIDR = "10.42.10.0/24";

        # LXC: host manages root and storage. Disks must be empty.
        storage.disks = [];
      };
    };
  };
}
