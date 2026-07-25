{
  pkgs,
  lib,
  nodeName,
  nodeConfig,
  ...
}: let
  isLxc = nodeConfig.platform == "lxc";
in {
  nixpkgs.config.allowUnfree = true;

  imports = [
    ./options.nix
    ./users.nix
    ./ssh.nix
    ./performance.nix
  ];

  boot.isContainer = isLxc;
  boot.kernelModules = lib.mkIf isLxc (lib.mkForce []);
  # A recursive /nix/store bind mount loses the Proxmox UID mapping in
  # unprivileged LXC containers, exposing store files as uid 100000.
  boot.nixStoreMountOpts = lib.mkIf isLxc (lib.mkForce []);
  systemd.suppressedSystemUnits = lib.optionals isLxc ["sys-kernel-debug.mount"];

  boot.kernel.sysctl = lib.mkIf isLxc {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  boot.loader = lib.mkIf (!isLxc) {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  services.qemuGuest.enable = !isLxc;
  services.spice-vdagentd.enable = !isLxc;

  boot.kernelParams = lib.optionals (!isLxc) ["boot.shell_on_fail"];

  boot.initrd.availableKernelModules = lib.optionals (!isLxc) [
    "ahci"
    "geneve"
    "nvme"
    "sd_mod"
    "uas"
    "usb_storage"
    "virtio_console"
    "virtio_pci"
    "virtio_scsi"
    "xhci_pci"
  ];

  services.lvm.enable = !isLxc;
  services.chrony.enable = !isLxc;

  system.stateVersion = lib.trivial.release;
  time.timeZone = "UTC";
  networking.hostName = nodeName;

  environment.systemPackages = with pkgs; [
    bind.dnsutils
    conntrack-tools
    cri-tools
    curl
    dmidecode
    e2fsprogs
    ethtool
    htop
    iotop
    jq
    kitty.terminfo
    lshw
    lsof
    mtr
    nerdctl
    nfs-utils
    parted
    pciutils
    smartmontools
    strace
    tcpdump
    tmux
    vim
  ];

  # Longhorn and k3s expect mount.nfs, umount.nfs, mount, umount under /usr/local/sbin
  systemd.tmpfiles.rules = [
    "L+ /usr/local/sbin/mount.nfs  - - - - ${pkgs.nfs-utils}/bin/mount.nfs"
    "L+ /usr/local/sbin/umount.nfs - - - - ${pkgs.nfs-utils}/bin/umount.nfs"
    "L+ /usr/local/sbin/mount      - - - - ${pkgs.util-linux}/bin/mount"
    "L+ /usr/local/sbin/umount     - - - - ${pkgs.util-linux}/bin/umount"
  ];

  nix.settings.experimental-features = ["nix-command" "flakes"];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
}
