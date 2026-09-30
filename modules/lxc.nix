# LXC platform: an existing NixOS container on a host that offers no hardware
# virtualisation. The host owns the kernel, its modules and global sysctls;
# k3s-preflight refuses to start k3s while the host is missing something and
# says what to change (docs/lxc.md). New generations are activated by
# restarting the container (the CLI does that), not by switching live.
{
  lib,
  pkgs,
  inputs,
  node,
  ...
}: let
  # Values the kubelet insists on. It writes them itself when /proc/sys is
  # writable; with the recommended read-only /proc/sys the host sets them.
  kubeletSysctls = {
    "vm/overcommit_memory" = "1";
    "vm/panic_on_oom" = "0";
    "kernel/panic" = "10";
    "kernel/panic_on_oops" = "1";
    "kernel/keys/root_maxkeys" = "1000000";
    "kernel/keys/root_maxbytes" = "25000000";
  };
in {
  imports = ["${inputs.nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"];

  boot.kernelModules = lib.mkForce [];
  # A recursive /nix/store bind mount loses the Proxmox UID mapping in
  # unprivileged containers, exposing store files as uid 100000.
  boot.nixStoreMountOpts = lib.mkForce [];

  services = {
    lvm.enable = false;
    # The Proxmox console (pct console, web UI) logs in as admin: whoever can
    # reach it already controls the host.
    getty.autologinUser = "admin";
    # nf_conntrack_max is global; leave it to the host instead of failing.
    k3s.extraFlags = ["--kube-proxy-arg=conntrack-max-per-core=0"];
  };

  systemd.suppressedSystemUnits = ["sys-kernel-debug.mount"];
  systemd.services = {
    console-getty = {
      enable = true;
      wantedBy = ["getty.target"];
    };
    k3s-preflight = {
      description = "Check the LXC host provides what k3s needs";
      before = ["k3s.service"];
      requiredBy = ["k3s.service"];
      path = [pkgs.util-linux];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        missing=()
        need() { missing+=("$*"); }
        [[ $(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]] || need "cgroup v2 (Proxmox 7 or later)"
        [[ -c /dev/kmsg ]] || need "/dev/kmsg bind-mounted into the container"
        for m in overlay br_netfilter vxlan wireguard ${lib.optionalString (lib.elem "storage" node.roles) "iscsi_tcp"}; do
          [[ -d /sys/module/$m ]] || need "kernel module $m loaded on the host"
        done
        ${lib.concatStrings (lib.mapAttrsToList (key: value: ''
            [[ $(</proc/sys/${key}) == ${value} || -w /proc/sys/${key} ]] ||
              need "sysctl ${builtins.replaceStrings ["/"] ["."] key}=${value} on the host"
          '')
          kubeletSysctls)}
        ${lib.optionalString (lib.elem "storage" node.roles) ''
          mountpoint -q /data || need "the Longhorn disk mounted on /data"
          [[ $(ulimit -l) == unlimited ]] || need "lxc.prlimit.memlock: unlimited"
        ''}
        if ((''${#missing[@]})); then
          echo "k3s cannot run until the LXC host provides (see docs/lxc.md):" >&2
          printf '  - %s\n' "''${missing[@]}" >&2
          exit 1
        fi
      '';
    };
  };
}
