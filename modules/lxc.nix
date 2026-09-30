# LXC platform: an existing NixOS container. The Proxmox host owns the kernel,
# devices and mounts; a preflight unit refuses to start k3s on a host that is
# missing something (see docs/lxc.md).
{
  lib,
  pkgs,
  inputs,
  node,
  ...
}: {
  imports = ["${inputs.nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"];

  boot.kernelModules = lib.mkForce [];
  # A recursive /nix/store bind mount loses the Proxmox UID mapping in
  # unprivileged containers, exposing store files as uid 100000.
  boot.nixStoreMountOpts = lib.mkForce [];
  systemd.suppressedSystemUnits = ["sys-kernel-debug.mount"];
  services.lvm.enable = false;

  systemd.services.k3s-preflight = {
    description = "Check the LXC host provides what k3s needs";
    before = ["k3s.service"];
    requiredBy = ["k3s.service"];
    path = [pkgs.util-linux];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      fail() { echo "LXC host setup incomplete: $*" >&2; exit 1; }
      [ "$(stat -fc %T /sys/fs/cgroup)" = cgroup2fs ] || fail "cgroup v2 is required"
      [ -c /dev/kmsg ] || fail "bind-mount /dev/kmsg into the container"
      findmnt -no OPTIONS -T /proc/sys | grep -qw rw || fail "/proc/sys must be writable (lxc.mount.auto: proc:rw sys:rw)"
      for m in overlay br_netfilter vxlan wireguard; do
        [ -d "/sys/module/$m" ] || fail "load kernel module $m on the host"
      done
      ${lib.optionalString (lib.elem "storage" node.roles) ''
        mountpoint -q /data || fail "mount the Longhorn disk on /data"
        [ -d /sys/module/iscsi_tcp ] || fail "load kernel module iscsi_tcp on the host"
        [ "$(ulimit -l)" = unlimited ] || fail "set lxc.prlimit.memlock: unlimited"
      ''}
    '';
  };
}
