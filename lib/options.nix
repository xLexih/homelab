# Schema of clusters/<name>/cluster.nix.
{
  lib,
  config,
  ...
}: let
  inherit (lib) mkOption types;
  ipv4 = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}";
  cidr = types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}";
  servers = lib.attrNames (lib.filterAttrs (_: n: lib.elem "server" n.roles) config.nodes);

  node = {
    name,
    config,
    ...
  }: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        readOnly = true;
        internal = true;
      };
      roles = mkOption {
        type = types.listOf (types.enum ["server" "storage" "gpu"]);
        default = [];
        description = ''
          server:  control plane and etcd member (use 1, 3 or 5 servers).
          storage: holds Longhorn replicas on /data. Longhorn is deployed
                   when at least one node has this role.
          gpu:     NVIDIA driver, container runtime and device plugin.
          Every node runs workloads.
        '';
      };
      platform = mkOption {
        type = types.enum ["vm" "lxc"];
        default = "vm";
        description = "vm: disks managed by disko. lxc: existing NixOS container; the host owns kernel, disks and mounts.";
      };
      location = mkOption {
        type = types.str;
        default = "default";
        description = "Nodes in the same location reach each other over the LAN; other locations use `endpoint`.";
      };
      wgIP = mkOption {
        type = ipv4;
        description = "Address on the WireGuard mesh; Kubernetes runs entirely on this network.";
      };
      address = mkOption {
        type = types.nullOr cidr;
        default = null;
        example = "192.168.1.10/24";
        description = "Static LAN address with prefix length; null uses DHCP (then `endpoint` is required).";
      };
      gateway = mkOption {
        type = types.nullOr ipv4;
        default = null;
      };
      interface = mkOption {
        type = types.str;
        default = "ens18";
        description = "LAN interface for the static address and the virtual IP.";
      };
      endpoint = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Public DNS name or IP used for SSH and by WireGuard peers in other locations.";
      };
      sshPort = mkOption {
        type = types.port;
        default = 22;
      };
      disk = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/dev/sda";
        description = "VM system disk (EFI, root, and an etcd volume on servers). Erased by `install`.";
      };
      dataDisk = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "VM disk mounted on /data for Longhorn; required for storage nodes. Erased by `install`.";
      };
      ip = mkOption {
        type = types.nullOr types.str;
        default =
          if config.address == null
          then null
          else builtins.head (lib.splitString "/" config.address);
        readOnly = true;
        internal = true;
      };
      sshHost = mkOption {
        type = types.nullOr types.str;
        default =
          if config.endpoint != null
          then config.endpoint
          else config.ip;
        readOnly = true;
        internal = true;
      };
    };
  };
in {
  options = {
    name = mkOption {
      type = types.strMatching "[a-z][-a-z0-9]*";
      readOnly = true;
      description = "Directory name under clusters/.";
    };
    stateVersion = mkOption {
      type = types.str;
      description = "NixOS release of the first installation; never change it afterwards.";
    };
    init = mkOption {
      type = types.nullOr types.str;
      default =
        if builtins.length servers == 1
        then builtins.head servers
        else null;
      defaultText = "the only server";
      description = "Server that bootstrapped etcd. Required when there are several servers; never change it.";
    };
    loadBalancerIPs = mkOption {
      type = types.listOf (types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2}|-([0-9]{1,3}\\.){3}[0-9]{1,3})?");
      default = [];
      example = ["192.168.1.50" "192.168.1.60-192.168.1.69" "192.168.1.80/29"];
      description = ''
        LAN addresses for services of type LoadBalancer: single addresses,
        ranges or CIDRs, each inside the subnet of some nodes' `address`.
        Every service gets its own address (MetalLB, layer 2), announced by
        one of those nodes and moved to another when it fails. Pin one with
        the annotation `metallb.io/loadBalancerIPs`.
        Empty: k3s ServiceLB publishes services on every node's address, one
        service per port.
      '';
    };
    gpuSharing = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "Pods that may share one GPU (NVIDIA time-slicing).";
    };
    etcdS3 = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          endpoint = mkOption {type = types.str;};
          bucket = mkOption {type = types.str;};
          region = mkOption {
            type = types.str;
            default = "us-east-1";
          };
        };
      });
      default = null;
      description = ''
        Off-site copy of the etcd snapshots. Credentials live in
        secrets/etcd-s3.age (AWS_ACCESS_KEY_ID=… and AWS_SECRET_ACCESS_KEY=…).
      '';
    };
    network = {
      podCIDR = mkOption {
        type = cidr;
        default = "10.42.0.0/16";
      };
      serviceCIDR = mkOption {
        type = cidr;
        default = "10.43.0.0/16";
      };
      wgCIDR = mkOption {
        type = cidr;
        default = "10.100.0.0/24";
      };
      wgPort = mkOption {
        type = types.port;
        default = 51820;
      };
      nameservers = mkOption {
        type = types.listOf ipv4;
        default = ["1.1.1.1" "9.9.9.9"];
        description = "Upstream DNS for nodes with a static address.";
      };
    };
    nodes = mkOption {
      type = types.attrsOf (types.submodule node);
      description = "Node name -> node settings. Names become hostnames and Kubernetes node names.";
    };
  };
}
