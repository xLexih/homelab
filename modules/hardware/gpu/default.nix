# modules/hardware/gpu/default.nix
{
  config,
  lib,
  pkgs,
  nodeConfig,
  ...
}: {
  imports = [
    ./device-plugin.nix
  ];

  config = lib.mkIf nodeConfig.gpu.enable (lib.mkMerge [
    (lib.mkIf (nodeConfig.gpu.vendor == "nvidia") {
      services.xserver.videoDrivers = ["nvidia"];

      hardware.nvidia = {
        open = true;
        modesetting.enable = true;
        powerManagement.enable = false;
        package = config.boot.kernelPackages.nvidiaPackages.production;
        nvidiaPersistenced = true;
      };

      hardware.graphics.enable = true;

      hardware.nvidia-container-toolkit = {
        enable = true;
        mount-nvidia-executables = true;
        extraArgs = ["--device-name-strategy=uuid"];
      };

      boot.kernelModules = ["nvidia" "nvidia_uvm" "nvidia_drm" "nvidia_modeset"];
      boot.initrd.availableKernelModules = ["nvidia" "nvidia_uvm"];

      environment.systemPackages = with pkgs; [
        cudaPackages.cudatoolkit
        cudaPackages.cuda_gdb
        lshw
        pciutils
        nvidia-container-toolkit
      ];

      services.udev.extraRules = ''
        KERNEL=="nvidia", MODE="0660", OWNER="root", GROUP="video"
        KERNEL=="nvidia*", MODE="0660", OWNER="root", GROUP="video"
        KERNEL=="nvidiactl", MODE="0660", OWNER="root", GROUP="video"
        KERNEL=="nvidia-modeset", MODE="0660", OWNER="root", GROUP="video"
        KERNEL=="nvidia-uvm", MODE="0660", OWNER="root", GROUP="video"
        KERNEL=="nvidia-uvm-tools", MODE="0660", OWNER="root", GROUP="video"
        SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0660", OWNER="root", GROUP="video"
        SUBSYSTEM=="drm", KERNEL=="card*", MODE="0660", OWNER="root", GROUP="video"
      '';
    })
  ]);
}
