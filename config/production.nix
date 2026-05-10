{...}: {
  cluster = {
    name = "production";
    # "longhorn" for distributed HA, "local" for hdd-only clusters (avoids etcd i/o contention)
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
    };

    loadBalancer = {
      enabled = true;
      pools.home = {
        start = "192.168.2.150";
        stop = "192.168.2.160";
      };
    };

    locations.home = {
      description = "Home Lab";
    };

    nodes = {
      master1 = {
        roles = [
          "master"
          "worker"
          "storage"
        ];
        location = "home";
        init = true;
        network = {
          wgIP = "10.100.0.1";
          lanIP = "192.168.2.105";
          gateway = "192.168.2.1";
          sshPort = 22;
          sshUser = "root";
        };
        podCIDR = "10.42.0.0/24";
        # GTX 1660 SUPER via Proxmox PCI passthrough
        gpu = {
          enable = true;
          vendor = "nvidia";
          pciId = "07:00";
          withCuda = true;
          model = "NVIDIA-GTX-1660-SUPER";
          memory = "6144Mi";
        };
        # sdb: SSD (system+etcd), sda: HDD (data)
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
      master2 = {
        roles = [
          "master"
          "worker"
          "storage"
        ];
        location = "home";
        network = {
          wgIP = "10.100.0.2";
          lanIP = "192.168.2.106";
          gateway = "192.168.2.1";
          sshPort = 22;
          sshUser = "root";
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
      master3 = {
        roles = [
          "master"
          "worker"
          "storage"
        ];
        location = "home";
        network = {
          wgIP = "10.100.0.3";
          lanIP = "192.168.2.107";
          gateway = "192.168.2.1";
          sshPort = 22;
          sshUser = "root";
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
