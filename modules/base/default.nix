{
  pkgs,
  lib,
  nodeName,
  ...
}: {
  nixpkgs.config.allowUnfree = true;

  imports = [
    ./options.nix
    ./users.nix
    ./ssh.nix
    ./performance.nix
  ];

  boot.loader = {
    systemd-boot.enable = true;
    efi.canTouchEfiVariables = true;
  };

  services.qemuGuest.enable = true;
  services.spice-vdagentd.enable = true; # Proxmox SPICE guest agent

  boot.kernelParams = ["boot.shell_on_fail"];

  boot.initrd.availableKernelModules = [
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

  services.lvm.enable = true;
  services.chrony.enable = true;

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
