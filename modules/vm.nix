# VM platform: EFI boot and a disko layout written by `install`.
# disk0 (node.disk):     EFI + LVM vg0 { etcd 10G, root rest }
# disk1 (node.dataDisk): /data for Longhorn
# The etcd volume exists on every VM so a node can become a server later
# without repartitioning. Keep these names: they are the partition labels.
{
  lib,
  inputs,
  node,
  ...
}: let
  fs = mountpoint: extra:
    {
      type = "filesystem";
      format = "ext4";
      inherit mountpoint;
    }
    // extra;
in {
  imports = [inputs.disko.nixosModules.disko];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    initrd.availableKernelModules = ["ahci" "nvme" "sd_mod" "uas" "usb_storage" "virtio_blk" "virtio_pci" "virtio_scsi" "xhci_pci"];
    kernelModules = ["br_netfilter" "overlay"];
    kernel.sysctl."net.bridge.bridge-nf-call-iptables" = 1;
  };
  services.qemuGuest.enable = true;

  disko.devices = {
    disk =
      {
        disk0 = {
          type = "disk";
          device = node.disk;
          content = {
            type = "gpt";
            partitions = {
              boot = {
                size = "512M";
                type = "EF00";
                content = fs "/boot" {
                  format = "vfat";
                  mountOptions = ["umask=0077"];
                };
              };
              lvm = {
                size = "100%";
                content = {
                  type = "lvm_pv";
                  vg = "vg0";
                };
              };
            };
          };
        };
      }
      // lib.optionalAttrs (node.dataDisk != null) {
        disk1 = {
          type = "disk";
          device = node.dataDisk;
          content = {
            type = "gpt";
            partitions.data = {
              size = "100%";
              content = fs "/data" {};
            };
          };
        };
      };

    lvm_vg.vg0 = {
      type = "lvm_vg";
      lvs = {
        etcd = {
          size = "10G";
          content = fs "/var/lib/rancher/k3s/server/db/etcd" {mountOptions = ["noatime" "discard"];};
        };
        root = {
          size = "100%FREE";
          content = fs "/" {};
        };
      };
    };
  };
}
