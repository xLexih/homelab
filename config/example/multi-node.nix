# Production HA cluster (3 VMs).
# - 3 VM nodes, each with master + worker + storage
# - Longhorn distributed block storage (2 replicas safe)
# - Docker Distribution registry on Longhorn (pushes work)
# - kube-vip LoadBalancer with Cilium IP pool on home LAN
# - NVIDIA GPU passthrough on one node (ML/AI workloads)
# - CoreDNS with 2 replicas (1 per 2 masters is the pattern)
#
# Use cases: production homelab, HA workloads, external-facing services.
# Copy to config/<name>.nix and add to flake.nix via mkCluster.
{...}: {
  cluster = {
    name = "multi";

    # Distributed HA block storage. Needs 3+ nodes with "storage"
    # role for data safety with 2 replicas. Longhorn disables k3s
    # local-path provisioner automatically.
    storageBackend = "longhorn";

    etcdSnapshotRetention = 30;

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

    # LoadBalancer pools keyed by location. Each pool defines a
    # range of VIPs that Cilium allocates from. kube-vip announces
    # the active VIP via ARP on the LAN (requires L2 connectivity).
    loadBalancer = {
      enable = true;
      pools.home = {
        start = "192.168.2.150";
        stop = "192.168.2.160";
      };
    };

    locations.home = {
      description = "Home Lab";
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
          sshUser = "nixos";
        };
        podCIDR = "10.42.0.0/24";

        # GPU passthrough on init node.
        # Prerequisites: Proxmox PCI passthrough, vfio-pci bound.
        # Verify PCI ID with: lspci -nn | grep -i nvidia
        gpu = {
          enable = true;
          vendor = "nvidia";
          pciId = "07:00";
          # model and memory are Kubernetes node labels for
          # workload scheduling visibility.
          model = "NVIDIA-GTX-1660-SUPER";
          memory = "6144Mi";
        };

        # SSD: system + etcd (dedicated etcd partition
        # improves control-plane stability).
        # HDD: Longhorn data (bulk storage).
        storage = {
          disks = [
            {
              device = "/dev/sdb";
              roles = ["system" "etcd"];
              sizes = {
                system = "40G";
                etcd = "100%FREE";
              };
            }
            {
              device = "/dev/sda";
              roles = ["data"];
            }
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
          sshUser = "nixos";
        };
        podCIDR = "10.42.1.0/24";
        storage = {
          disks = [
            {
              device = "/dev/sdb";
              roles = ["system" "etcd"];
              sizes = {
                system = "40G";
                etcd = "100%FREE";
              };
            }
            {
              device = "/dev/sda";
              roles = ["data"];
            }
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
          sshUser = "nixos";
        };
        podCIDR = "10.42.2.0/24";
        storage = {
          disks = [
            {
              device = "/dev/sdb";
              roles = ["system" "etcd"];
              sizes = {
                system = "40G";
                etcd = "100%FREE";
              };
            }
            {
              device = "/dev/sda";
              roles = ["data"];
            }
          ];
        };
      };
    };
  };
}
