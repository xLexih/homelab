# Three-node HA cluster: every node is a server, a Longhorn storage node and
# a workload node; master1 also carries the GPU.
{
  k3sVersion = "1.35";
  stateVersion = "26.05";
  init = "master1";
  clusterId = 1;
  loadBalancerIPs = ["192.168.2.150-192.168.2.160"];
  gpuSharing = 3;
  # images keep their in-cluster name; nodes pull through registry-lb
  registries.mirrors."registry-docker-registry.registry.svc.cluster.local:5000".endpoint = ["http://192.168.2.151:5000"];

  nodes = {
    master1 = {
      roles = ["server" "storage" "gpu"];
      wgIP = "10.100.0.1";
      address = "192.168.2.105/24";
      gateway = "192.168.2.1";
      disk = "/dev/sdb";
      dataDisk = "/dev/sda";
    };
    master2 = {
      roles = ["server" "storage"];
      wgIP = "10.100.0.2";
      address = "192.168.2.106/24";
      gateway = "192.168.2.1";
      disk = "/dev/sdb";
      dataDisk = "/dev/sda";
    };
    master3 = {
      roles = ["server" "storage"];
      wgIP = "10.100.0.3";
      address = "192.168.2.107/24";
      gateway = "192.168.2.1";
      disk = "/dev/sdb";
      dataDisk = "/dev/sda";
    };
  };
}
