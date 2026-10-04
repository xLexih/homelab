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
    k3sVersion = mkOption {
      type = types.strMatching "1\\.[0-9]+";
      example = "1.35";
      description = ''
        Kubernetes minor version, i.e. the nixpkgs package k3s_1_35. Patch
        releases follow flake.lock. Upgrade one minor version at a time and
        let `switch all` do the servers before the agents.
      '';
    };
    reserved = {
      server = mkOption {
        type = types.str;
        default = "cpu=500m,memory=1Gi";
        description = "Kept away from pods on servers (kubelet system-reserved) for the OS, k3s, etcd and the API server.";
      };
      agent = mkOption {
        type = types.str;
        default = "cpu=250m,memory=512Mi";
        description = "Kept away from pods on agents (kubelet system-reserved) for the OS and k3s.";
      };
    };
    init = mkOption {
      type = types.nullOr types.str;
      default =
        if builtins.length servers == 1
        then builtins.head servers
        else null;
      defaultText = "the only server";
      description = ''
        Server that creates the cluster (k3s --cluster-init); every other node
        joins through any running server. Required with several servers.
        Once the cluster exists it may name any server that has already
        joined, e.g. when removing this one; never a server that is still to
        be installed, which would start a second cluster.
      '';
    };
    clusterId = mkOption {
      type = types.nullOr (types.ints.between 1 255);
      default = null;
      description = ''
        Cilium cluster ID, unique among clusters that will ever be connected
        with ClusterMesh. Set it before workloads run: changing it later
        means restarting every pod.
      '';
    };
    loadBalancerIPs = mkOption {
      type = types.listOf (types.strMatching "([0-9]{1,3}\\.){3}[0-9]{1,3}(/[0-9]{1,2}|-([0-9]{1,3}\\.){3}[0-9]{1,3})?");
      default = [];
      example = ["192.168.1.50" "192.168.1.60-192.168.1.69" "192.168.1.80/29"];
      description = ''
        Addresses for services of type LoadBalancer: single addresses, ranges
        or CIDRs. Every service gets its own address (Cilium LB IPAM). An
        entry inside the subnet of some nodes' `address` is announced over
        ARP by one of those nodes, which another replaces when it fails;
        those nodes must share one `location`. Entries outside every subnet
        need `bgp`. Pin an address with the annotation `lbipam.cilium.io/ips`.
        Empty (and no `bgp`): services get the addresses of the nodes.
      '';
    };
    bgp = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          asn = mkOption {
            type = types.ints.between 1 4294967295;
            description = "AS number of the cluster's nodes.";
          };
          peers = mkOption {
            type = types.listOf (types.submodule {
              options = {
                address = mkOption {type = ipv4;};
                asn = mkOption {type = types.ints.between 1 4294967295;};
              };
            });
            description = "Routers; each peers with the nodes whose `address` subnet contains it.";
          };
        };
      });
      default = null;
      description = ''
        Advertise LoadBalancer addresses to routers over BGP (Cilium BGP
        control plane), in addition to ARP. Off when null.
      '';
    };
    registries = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      example = {
        mirrors."registry.lan:5000".endpoint = ["http://192.168.1.51:5000"];
      };
      description = ''
        Written to every node as k3s' registries.yaml (mirrors, credentials,
        TLS); see https://docs.k3s.io/installation/private-registry. Nodes
        don't resolve cluster DNS, so point mirrors at LAN addresses, e.g. a
        registry's LoadBalancer address.
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
      wgMTU = mkOption {
        type = types.ints.between 1280 1500;
        default = 1420;
        description = "MTU of wg0. Lower it when a link between locations has a smaller MTU (PPPoE: 1412).";
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
