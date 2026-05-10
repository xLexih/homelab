{
  lib,
  nodeConfig,
  ...
}: let
  cfg = nodeConfig.storage;

  hasRole = role: lib.any (d: lib.elem role d.roles) cfg.disks;

  # Build a disko partition attrset for a single disk based on its assigned roles.
  # Only the partition for the first role listed on a disk is created here;
  # additional roles that share the system disk are handled via LVM.
  mkDiskPartitions = idx: disk: let
    name = "disk${toString idx}";
    hasSystem = lib.elem "system" disk.roles;
    hasEtcd = lib.elem "etcd" disk.roles && !hasSystem;
    hasData = lib.elem "data" disk.roles && !hasSystem;

    partitions =
      (lib.optionalAttrs hasSystem {
        boot = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
          };
        };
        lvm = {
          size = "100%";
          content = {
            type = "lvm_pv";
            vg = "vg0";
          };
        };
      })
      // (lib.optionalAttrs hasEtcd {
        etcd = {
          size = disk.sizes.etcd;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/var/lib/rancher/k3s/server/db/etcd";
            # noatime/nodiratime reduce write amplification on SSD;
            # discard enables continuous TRIM for sustained performance
            mountOptions = ["noatime" "nodiratime" "discard"];
          };
        };
      })
      // (lib.optionalAttrs hasData {
        data = {
          size = disk.sizes.data;
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/data";
          };
        };
      });
  in
    lib.nameValuePair name {
      inherit (disk) device;
      type = "disk";
      content = {
        type = "gpt";
        inherit partitions;
      };
    };

  diskConfigs = lib.listToAttrs (lib.imap0 mkDiskPartitions cfg.disks);

  # The single disk that carries the 'system' role
  systemDisk = lib.findFirst (d: lib.elem "system" d.roles) null cfg.disks;
in {
  assertions = [
    {
      assertion = cfg.disks != [];
      message = "At least one disk must be configured";
    }
    {
      assertion = systemDisk != null;
      message = "One disk must have the 'system' role for EFI + root";
    }
    {
      assertion =
        lib.length (lib.concatMap (d: d.roles) cfg.disks)
        == lib.length (lib.unique (lib.concatMap (d: d.roles) cfg.disks));
      message = "Each role (system, data, etcd) must be assigned to only one disk";
    }
  ];

  disko.devices = {
    disk = diskConfigs;

    # LVM is only created when the system disk also carries etcd and/or data roles.
    # Dedicated etcd/data disks are formatted directly as partitions above.
    lvm_vg = lib.mkIf (systemDisk != null) {
      vg0 = {
        type = "lvm_vg";
        lvs =
          {
            root = {
              size = systemDisk.sizes.system;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          }
          // (lib.optionalAttrs (lib.elem "etcd" systemDisk.roles) {
            etcd = {
              size = systemDisk.sizes.etcd;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/var/lib/rancher/k3s/server/db/etcd";
                mountOptions = ["noatime" "nodiratime" "discard"];
              };
            };
          })
          // (lib.optionalAttrs (lib.elem "data" systemDisk.roles) {
            data = {
              size = systemDisk.sizes.data;
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/data";
              };
            };
          });
      };
    };
  };

  # k3s must start only after the etcd filesystem is mounted
  systemd.services.k3s = lib.mkIf (hasRole "etcd") {
    requires = lib.mkAfter ["var-lib-rancher-k3s-server-db-etcd.mount"];
    after = lib.mkAfter ["var-lib-rancher-k3s-server-db-etcd.mount"];
  };
}
