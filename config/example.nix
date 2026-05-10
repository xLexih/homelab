# Example cluster configuration. every available option is shown with its
# default value (commented out) 
#
# Copy this file to config/production.nix and modify it.
{...}: {
  cluster = {
    name = "example-cluster"; # arbitrary, used only for logging

    # Storage backend:
    #   "local"    — k3s local-path provisioner (no replicas, single node)
    #   "longhorn" — distributed block storage with replicas (requires "storage" role)
    storageBackend = "longhorn";

    # Number of etcd snapshots to keep (pruned daily)
    etcdSnapshotRetention = 30; # default: 30

    # Registry type:
    #   "none"   — no in-cluster registry
    #   "k3s"    — embedded P2P registry (Spegel), no persistent storage
    #   "docker" — Docker Distribution with persistent storage (needs longhorn)
    registry = {
      type = "docker"; # default: "none"
      storageSize = "20Gi"; # default: "20Gi"   (only when type="docker")
      replicas = 2; # default: 1        (only when type="docker")
      enableUI = true; # default: true     (docker-registry-ui)
      http = true; # default: true     (plain HTTP; set false for HTTPS)
    };

    network = {
      serviceCIDR = "10.43.0.0/16"; # default: "10.43.0.0/16"
      podCIDR = "10.42.0.0/16"; # default: "10.42.0.0/16"
      wgCIDR = "10.100.0.0/24"; # WireGuard overlay; MUST be set
      wgPort = 51820; # default: 51820
      wgMTU = 1440; # default: 1440  (60 bytes overhead for WG)
      domain = "homelab.example.com"; # default: null   (used to derive node endpoints)
      lanInterface = "ens18"; # default: "ens18"
      nameservers = ["1.1.1.1" "8.8.8.8"]; # default: ["1.1.1.1" "8.8.8.8"]
      wgKeepalive = 25; # default: 25  (seconds, for NAT traversal)
      apiServerPort = 6443; # default: 6443
    };

    # LoadBalancer (kube-vip + Cilium IP pools)
    loadBalancer = {
      enabled = true; # default: false
      pools = {
        home = {
          start = "192.168.2.150"; # first assignable VIP
          stop = "192.168.2.160"; # last assignable VIP
        };
        cloud = {
          start = "10.10.0.150";
          stop = "10.10.0.160";
        };
        # Add more locations as needed
      };
    };

    # Locations (must match values used in nodes.<name>.location)
    locations = {
      home = {description = "Home Lab";};
      cloud = {description = "VPS Provider";};
      office = {description = "Remote Office";};
      # default: {}   (when no locations are defined)
    };

    coredns = {
      replicas = 2; # default: 2   (recommend 2 for HA)
    };

    # Nodes
    nodes = {
      node1 = {
        # Roles: "master" (control-plane), "worker" (runs pods), "storage" (Longhorn)
        roles = ["master" "worker" "storage"];
        location = "home"; # must be defined in locations above
        init = true; # exactly one master must be init

        network = {
          wgIP = "10.100.0.1"; # unique WireGuard IP
          lanIP = "192.168.2.101"; # required if useDHCP=false
          gateway = "192.168.2.1"; # required if useDHCP=false
          lanPrefixLength = 24; # default: 24
          useDHCP = false; # default: false  (true requires endpoint or domain)
          wgPort = null; # default: null   (falls back to cluster.network.wgPort)
          endpoint = null; # default: null   (overrides <nodeName>.<domain>)
          sshPort = null; # default: null   (defaults to 22)
          sshUser = null; # default: null   (defaults to "nixos")
        };

        podCIDR = "10.42.0.0/24"; # unique per node; required

        # GPU (only NVIDIA is implemented; leave enable=false if not needed)
        gpu = {
          enable = false; # default: false
          vendor = "nvidia"; # default: "nvidia"   (only "nvidia" is supported)
          pciId = ""; # default: ""         (from lspci, e.g. "07:00")
          withCuda = true; # default: true
          model = null; # default: null       (e.g. "NVIDIA-GTX-1660-SUPER")
          memory = null; # default: null       (e.g. "6144Mi")
        };

        # Disk layout – see modules/base/options.nix for full description.
        # At least one disk must have the "system" role.
        # Roles are unique across disks.
        storage = {
          disks = [
            {
              device = "/dev/sda";
              roles = ["system" "etcd"]; # EFI+root + etcd on the same SSD
              sizes = {
                system = "44G"; # default: "50G"
                etcd = "20G"; # default: "30G"
              };
            }
            {
              device = "/dev/sdb";
              roles = ["data"]; # dedicated Longhorn data disk
              # sizes.data defaults to "100%" (rest of disk)
            }
          ];
        };
      };

      node2 = {
        roles = ["master" "worker" "storage"];
        location = "home";
        # init = false;                    # default: false

        network = {
          wgIP = "10.100.0.2";
          lanIP = "192.168.2.102";
          gateway = "192.168.2.1";
          # useDHCP = false;
        };

        podCIDR = "10.42.1.0/24";

        storage = {
          disks = [
            {
              device = "/dev/sda";
              roles = ["system" "etcd"];
              sizes = {
                system = "44G";
                etcd = "20G";
              };
            }
            {
              device = "/dev/sdb";
              roles = ["data"];
            }
          ];
        };
      };

      node3 = {
        roles = ["master" "worker"]; # no "storage" role – only runs containers
        location = "home";

        network = {
          wgIP = "10.100.0.3";
          lanIP = "192.168.2.103";
          gateway = "192.168.2.1";
        };

        podCIDR = "10.42.2.0/24";

        storage = {
          disks = [
            {
              device = "/dev/sda";
              roles = ["system"]; # single disk, everything on one drive
              # sizes.system defaults to "50G"
            }
          ];
        };
      };

      worker1 = {
        roles = ["worker" "storage"]; # worker + storage, no control-plane
        location = "home";

        network = {
          wgIP = "10.100.0.10";
          lanIP = "192.168.2.110";
          gateway = "192.168.2.1";
        };

        podCIDR = "10.42.10.0/24";

        storage = {
          disks = [
            {
              device = "/dev/sda";
              roles = ["system" "data"]; # system + data on a single disk (LVM)
              # sizes.system defaults to "50G", sizes.data defaults to "100%"
            }
          ];
        };
      };

      worker2 = {
        roles = ["worker"];
        location = "cloud";

        network = {
          wgIP = "10.100.0.11";
          useDHCP = true; # obtain LAN IP via DHCP
          # lanIP and gateway not needed
          endpoint = "worker-cloud.homelab.example.com"; # mandatory with DHCP (or set cluster.network.domain)
          # sshPort = null;                # default: null (-> 22)
          # sshUser = null;                # default: null (-> "nixos")
        };

        podCIDR = "10.42.11.0/24";

        storage = {
          disks = [
            {
              device = "/dev/vda"; # virtual disk (cloud VPS)
              roles = ["system"];
              sizes = {system = "15G";}; # smaller root for a thin VM
            }
          ];
        };
      };
    };
  };
}
