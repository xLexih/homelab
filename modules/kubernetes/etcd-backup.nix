{
  lib,
  pkgs,
  clusterConfig,
  helpers,
  nodeName,
  nodeConfig,
  ...
}: let
  retention = clusterConfig.etcdSnapshotRetention;
in
  lib.mkIf (helpers.hasRole "master" nodeConfig) {
    # Ensure the snapshot directory exists
    systemd.tmpfiles.rules = [
      "d /var/lib/rancher/k3s/server/db/snapshots 0750 root root -"
    ];

    # Oneshot service that creates a timestamped etcd snapshot
    # and prunes snapshots older than `retention` generations.
    systemd.services.etcd-backup = {
      description = "ETCD Snapshot";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "etcd-backup" ''
          set -euo pipefail
          TIMESTAMP=$(${pkgs.coreutils}/bin/date +%Y%m%d-%H%M%S)
          ${pkgs.k3s}/bin/k3s etcd-snapshot save --name "${nodeName}-$TIMESTAMP"
          ${pkgs.coreutils}/bin/ls -t /var/lib/rancher/k3s/server/db/snapshots/ 2>/dev/null \
            | ${pkgs.coreutils}/bin/tail -n +${toString (retention + 1)} \
            | ${pkgs.findutils}/bin/xargs -r -I {} rm -f /var/lib/rancher/k3s/server/db/snapshots/{}
        '';
      };
    };

    # Daily timer; Persistent=true ensures missed backups run after a reboot.
    systemd.timers.etcd-backup = {
      description = "Daily ETCD Backup";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1800";
        Persistent = true;
      };
    };
  }
