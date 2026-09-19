{...}: {
  cluster = {
    name = "teddysmp";
    stateVersion = "26.05";
    storageBackend = "local";

    etcdSnapshotRetention = 30;

    registry = {
      type = "docker";
      storageSize = "10Gi";
      replicas = 1;
      enableUI = false;
      http = true;
    };

    network = {
      serviceCIDR = "10.44.0.0/16";
      podCIDR = "10.45.0.0/16";
      wgCIDR = "10.101.0.0/24";
      wgPort = 51820;
      nodePorts = [32022];
      domain = null;
      lanInterface = "eth0";
    };

    loadBalancer = {
      enable = true;
      pools.teddysmp = {
        start = "192.168.2.150";
        stop = "192.168.2.150";
      };
    };

    locations.teddysmp = {
      description = "TeddySMP US Datacenter";
    };

    coredns.replicas = 1;

    nodes = {
      teddysmp = {
        platform = "lxc";
        roles = [
          "master"
          "worker"
        ];
        location = "teddysmp";
        init = true;
        network = {
          wgIP = "10.101.0.1";
          useDHCP = false;
          lanIP = "192.168.2.100";
          gateway = "192.168.2.1";
          endpoint = "teddysmp.com";
          endpointPort = 51820;
          sshPort = 22;
          sshUser = "admin";
        };
        podCIDR = "10.45.0.0/24";
        storage.disks = [];
      };
    };
  };
}
