{lib, ...}: let
  cidrType = lib.types.strMatching "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}/[0-9]{1,2}$";
  ipv4Type = lib.types.strMatching "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}$";
in {
  options.cluster = {
    name = lib.mkOption {
      type = lib.types.str;
      description = "Cluster name";
    };

    storageBackend = lib.mkOption {
      type = lib.types.enum ["local" "longhorn"];
      default = "local";
      description = ''
        Storage backend for the cluster.
        - local: k3s local-path provisioner (simple, no replicas)
        - longhorn: distributed block storage with replicas
      '';
    };

    etcdSnapshotRetention = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Number of etcd snapshots to retain";
    };

    network = lib.mkOption {
      type = lib.types.submodule {
        options = {
          serviceCIDR = lib.mkOption {
            type = cidrType;
            default = "10.43.0.0/16";
            description = "Kubernetes service CIDR range";
          };
          podCIDR = lib.mkOption {
            type = cidrType;
            default = "10.42.0.0/16";
            description = "Kubernetes pod CIDR range";
          };
          wgCIDR = lib.mkOption {
            type = cidrType;
            description = "WireGuard overlay network CIDR";
          };
          wgPort = lib.mkOption {
            type = lib.types.port;
            default = 51820;
            description = "WireGuard listen port";
          };
          wgMTU = lib.mkOption {
            type = lib.types.int;
            default = 1440;
            description = ''
              WireGuard interface MTU.
              Default 1440 accounts for WireGuard overhead (60 bytes) on standard 1500 byte links.
              Reduce if nesting tunnels (e.g. Cilium Geneve adds ~50 bytes).
            '';
          };
          domain = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Cluster domain; used to construct node endpoints if no explicit endpoint is set";
          };
          lanInterface = lib.mkOption {
            type = lib.types.str;
            default = "ens18";
            description = "Primary LAN network interface";
          };
          nameservers = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = ["1.1.1.1" "8.8.8.8"];
            description = "DNS nameservers for the cluster";
          };
          wgKeepalive = lib.mkOption {
            type = lib.types.int;
            default = 25;
            description = "WireGuard persistent keepalive interval in seconds (for NAT traversal)";
          };
          apiServerPort = lib.mkOption {
            type = lib.types.port;
            default = 6443;
            description = "Kubernetes API server port";
          };
        };
      };
      description = "Network configuration";
    };

    loadBalancer = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enabled = lib.mkEnableOption "LoadBalancer IP pools";
          pools = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options = {
                start = lib.mkOption {
                  type = ipv4Type;
                  description = "Start IP of the pool";
                };
                stop = lib.mkOption {
                  type = ipv4Type;
                  description = "End IP of the pool";
                };
              };
            });
            default = {};
            description = "IP pools keyed by location";
          };
        };
      };
      default = {};
      description = "LoadBalancer configuration";
    };

    locations = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Location description";
          };
        };
      });
      default = {};
      description = "Cluster locations";
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          roles = lib.mkOption {
            type = lib.types.listOf (lib.types.enum ["master" "worker" "storage"]);
            default = [];
            description = "Node roles";
          };
          location = lib.mkOption {
            type = lib.types.str;
            description = "Node location (must exist in cluster.locations)";
          };
          init = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether this node is the cluster init master";
          };
          network = lib.mkOption {
            type = lib.types.submodule {
              options = {
                wgIP = lib.mkOption {
                  type = ipv4Type;
                  description = "WireGuard IP address";
                };
                lanIP = lib.mkOption {
                  type = lib.types.nullOr ipv4Type;
                  default = null;
                  description = "LAN IP address (required if useDHCP is false)";
                };
                gateway = lib.mkOption {
                  type = lib.types.nullOr ipv4Type;
                  default = null;
                  description = "Default gateway (required if useDHCP is false)";
                };
                lanPrefixLength = lib.mkOption {
                  type = lib.types.int;
                  default = 24;
                  description = "LAN subnet prefix length";
                };
                useDHCP = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Use DHCP instead of static IP. Requires endpoint or cluster domain to be set.";
                };
                wgPort = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = "WireGuard port (overrides cluster default)";
                };
                endpoint = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "External endpoint for WireGuard (DNS or IP)";
                };
                sshPort = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = "SSH port (overrides default 22)";
                };
                sshUser = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "SSH user (defaults to nixos if null)";
                };
              };
            };
            description = "Node network configuration";
          };
          podCIDR = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Pod CIDR for this node (must be unique)";
          };
          gpu = lib.mkOption {
            type = lib.types.submodule {
              options = {
                enable = lib.mkEnableOption "GPU support for this node";
                vendor = lib.mkOption {
                  type = lib.types.enum ["nvidia" "amd"];
                  default = "nvidia";
                  description = "GPU vendor";
                };
                pciId = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = ''
                    PCI device ID of the GPU (e.g., '07:00').
                    Leave empty if no GPU is passed through.
                  '';
                };
                withCuda = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Install CUDA toolkit (NVIDIA only)";
                };
                model = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "NVIDIA-GTX-1660-SUPER";
                  description = "GPU model label for Kubernetes (e.g., NVIDIA-GTX-1660-SUPER)";
                };
                memory = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  example = "6144Mi";
                  description = "GPU memory label for Kubernetes (e.g., 6144Mi)";
                };
              };
            };
            default = {};
            description = "GPU configuration";
          };
          storage = lib.mkOption {
            type = lib.types.submodule {
              options = {
                disks = lib.mkOption {
                  type = lib.types.listOf (lib.types.submodule {
                    options = {
                      device = lib.mkOption {
                        type = lib.types.str;
                        example = "/dev/sda";
                        description = "Block device path";
                      };
                      roles = lib.mkOption {
                        type = lib.types.listOf (lib.types.enum ["system" "data" "etcd"]);
                        default = ["system"];
                        description = ''
                          Roles for this disk:
                          - system: EFI + root
                          - data: general storage (Longhorn)
                          - etcd: dedicated etcd partition (recommended on SSD)
                        '';
                      };
                      sizes = lib.mkOption {
                        type = lib.types.submodule {
                          options = {
                            system = lib.mkOption {
                              type = lib.types.str;
                              default = "50G";
                              description = "Size for system partition";
                            };
                            data = lib.mkOption {
                              type = lib.types.str;
                              default = "100%";
                              description = "Size for data partition (use '100%' for rest of disk)";
                            };
                            etcd = lib.mkOption {
                              type = lib.types.str;
                              default = "30G";
                              description = "Size for etcd partition";
                            };
                          };
                        };
                        default = {};
                        description = "Partition sizes per role";
                      };
                    };
                  });
                  default = [];
                  description = "Disks and their role-based partition layout";
                };
              };
            };
            default = {};
            description = "Node storage configuration";
          };
        };
      });
      default = {};
      description = "Cluster nodes";
    };

    registry = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum ["none" "k3s" "docker"];
            default = "none";
            description = ''
              In-cluster container registry type.
              - none: no registry
              - k3s: embedded distributed registry (Spegel)
              - docker: Docker Distribution with persistent storage
            '';
          };
          storageSize = lib.mkOption {
            type = lib.types.str;
            default = "20Gi";
            description = "Storage size for docker registry";
          };
          replicas = lib.mkOption {
            type = lib.types.int;
            default = 1;
            description = "Number of registry replicas";
          };
          enableUI = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable web UI for registry";
          };
          http = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Use HTTP (plain) for registry communication.
              If false, HTTPS is used (requires TLS certificates).
            '';
          };
        };
      };
      default = {};
      description = "In-cluster registry configuration";
    };

    coredns = lib.mkOption {
      type = lib.types.submodule {
        options = {
          replicas = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = "Number of CoreDNS replicas (recommended: 2 for HA)";
          };
        };
      };
      default = {};
      description = "CoreDNS configuration";
    };
  };
}
