# One-node cluster: master1 (Proxmox VM 100) is the server, the Longhorn
# storage node and the workload node, and carries the GPU.
{
  k3sVersion = "1.36";
  stateVersion = "26.05";
  init = "master1";
  clusterId = 1;
  loadBalancerIPs = ["192.168.2.150-192.168.2.160"];
  gpuSharing = 3;
  # images: registry.registry.svc.cluster.local:5000/<name>, pushed via kubectl
  # port-forward or https://registry.lexih.dev (an oTrust private service)
  registry = {
    address = "192.168.2.151";
    clientNamespaces = ["otrust"];
  };

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
  };
}
