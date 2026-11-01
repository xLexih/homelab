# Three-node HA cluster: every node is a server, a Longhorn storage node and
# a workload node; master1 also carries the GPU.
{
  k3sVersion = "1.36";
  stateVersion = "26.05";
  init = "master1";
  clusterId = 1;
  loadBalancerIPs = ["192.168.2.150-192.168.2.160"];
  gpuSharing = 3;
  # images: registry.registry.svc.cluster.local:5000/<name>, pushed via kubectl port-forward
  registry.address = "192.168.2.151";

  nodes = {
    master1 = {
      roles = ["server" "storage" "gpu"];
      tags = ["home"];
      wgIP = "10.100.0.1";
      address = "192.168.2.105/24";
      gateway = "192.168.2.1";
      disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      dataDisk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
    };
    master2 = {
      roles = ["server" "storage"];
      tags = ["home"];
      wgIP = "10.100.0.2";
      address = "192.168.2.106/24";
      gateway = "192.168.2.1";
      disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      dataDisk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
    };
    master3 = {
      roles = ["server" "storage"];
      tags = ["home"];
      wgIP = "10.100.0.3";
      address = "192.168.2.107/24";
      gateway = "192.168.2.1";
      disk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";
      dataDisk = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";
    };
  };
}
