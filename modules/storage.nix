# Longhorn, enabled by the first node with the "storage" role. Replicas live on
# /data of storage nodes only; every node can attach volumes, so every node gets
# the iSCSI/NFS client side. Without storage nodes k3s' local-path is used.
{
  lib,
  pkgs,
  cluster,
  node,
  ...
}: let
  nodes = lib.attrValues cluster.nodes;
  storageNodes = lib.filter (n: lib.elem "storage" n.roles) nodes;
  sidecars =
    if builtins.length nodes > 1
    then 2
    else 1;
in
  lib.mkIf (storageNodes != []) {
    services.openiscsi = {
      enable = true;
      name = "iqn.2016-04.com.open-iscsi:${node.name}";
    };
    boot.kernelModules = lib.optional (node.platform == "vm") "iscsi_tcp";
    environment.systemPackages = [pkgs.nfs-utils];

    # Longhorn runs host tools through nsenter at FHS paths.
    systemd.tmpfiles.rules = [
      "L+ /usr/bin/nsenter - - - - /run/current-system/sw/bin/nsenter"
      "L+ /usr/bin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
      "L+ /sbin/blkid - - - - /run/current-system/sw/bin/blkid"
      "L+ /usr/local/sbin/mount - - - - /run/current-system/sw/bin/mount"
      "L+ /usr/local/sbin/umount - - - - /run/current-system/sw/bin/umount"
      "L+ /usr/local/sbin/mount.nfs - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
      "L+ /usr/local/sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
    ];

    services.k3s.autoDeployCharts.longhorn = lib.mkIf (lib.elem "server" node.roles) {
      name = "longhorn";
      repo = "https://charts.longhorn.io";
      version = "1.12.1";
      hash = "sha256-yM9LNanYcs1ffkT9JtjmrHwquu5C9OLyoLDrvG46YRY=";
      targetNamespace = "longhorn-system";
      createNamespace = true;
      # A failed Longhorn upgrade must never be "fixed" by reinstalling it.
      extraFieldDefinitions.spec.failurePolicy = "abort";
      values = {
        persistence.defaultClassReplicaCount = lib.min 3 (builtins.length storageNodes);
        defaultSettings = {
          defaultDataPath = "/data";
          createDefaultDiskLabeledNodes = true;
          # Move pods of a dead node so their volumes can attach elsewhere.
          nodeDownPodDeletionPolicy = "delete-both-statefulset-and-deployment-pod";
        };
        csi = {
          attacherReplicaCount = sidecars;
          provisionerReplicaCount = sidecars;
          resizerReplicaCount = sidecars;
          snapshotterReplicaCount = sidecars;
        };
        longhornUI.replicas = 1;
      };
    };
  }
