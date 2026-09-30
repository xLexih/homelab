# NVIDIA GPUs: driver and container runtime on "gpu" nodes, device plugin on
# the servers once any node has the role. Pods request `nvidia.com/gpu` and
# `runtimeClassName: nvidia` (the RuntimeClass ships with k3s).
{
  lib,
  pkgs,
  config,
  cluster,
  node,
  ...
}: let
  anyGpu = lib.any (n: lib.elem "gpu" n.roles) (lib.attrValues cluster.nodes);
in
  lib.mkMerge [
    (lib.mkIf (lib.elem "gpu" node.roles) {
      nixpkgs.config.allowUnfree = true;
      services.xserver.videoDrivers = ["nvidia"];
      hardware = {
        graphics.enable = true;
        nvidia = {
          open = true;
          package = config.boot.kernelPackages.nvidiaPackages.production;
          nvidiaPersistenced = true;
        };
        nvidia-container-toolkit = {
          enable = true;
          mount-nvidia-executables = true;
          extraArgs = ["--device-name-strategy=uuid"];
        };
      };
      boot.kernelModules = ["nvidia" "nvidia_uvm"];

      # https://github.com/NixOS/nixpkgs/issues/288037
      services.k3s.containerdConfigTemplate = ''
        {{ template "base" . }}

        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
          runtime_type = "io.containerd.runc.v2"
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
          BinaryName = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi"
      '';
      systemd.services.k3s.serviceConfig.Environment = [
        "PATH=/run/current-system/sw/bin:/usr/local/bin:/nix/var/nix/profiles/default/bin"
      ];
    })

    (lib.mkIf (anyGpu && lib.elem "server" node.roles) {
      services.k3s.autoDeployCharts.nvidia-device-plugin = {
        name = "nvidia-device-plugin";
        repo = "https://nvidia.github.io/k8s-device-plugin";
        version = "0.19.3";
        hash = "sha256-jwEGdQDnElCP5V/gYLb4lYFNx+/By5YyPbLOT3d/bpY=";
        targetNamespace = "kube-system";
        extraFieldDefinitions.spec.failurePolicy = "abort";
        values =
          {
            runtimeClassName = "nvidia";
            nodeSelector."nvidia.com/gpu.present" = "true";
            affinity = null; # the chart's default needs node-feature-discovery labels
          }
          // lib.optionalAttrs (cluster.gpuSharing > 1) {
            config.map.default = builtins.toJSON {
              version = "v1";
              sharing.timeSlicing.resources = [
                {
                  name = "nvidia.com/gpu";
                  replicas = cluster.gpuSharing;
                }
              ];
            };
          };
      };
    })
  ]
