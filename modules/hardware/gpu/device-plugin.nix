# modules/hardware/gpu/device-plugin.nix
{
  lib,
  clusterConfig,
  helpers,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService kubectl;

  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;

  hasNvidiaGpu =
    lib.any
    (node: node.gpu.enable && node.gpu.vendor == "nvidia")
    (lib.attrValues clusterConfig.nodes);

  # https://github.com/NixOS/nixpkgs/issues/288037#issuecomment-4401306177
  devicePluginArgs = [
    "--set image.repository=nvcr.io/nvidia/k8s-device-plugin"
    "--set image.tag=v${versions.nvidiaDevicePlugin}"
    # Required for GFD to work properly
    # Time-slicing: split 1 GPU into 3 replicas (6 GB → ~2 GB per replica)
    "--set runtimeClassName=nvidia"
    # https://github.com/UntouchedWagons/K3S-NVidia/blob/main/values.yaml
    "--set config.map.default='version: v1\nflags:\n  migStrategy: none\nsharing:\n  timeSlicing:\n    renameByDefault: false\n    failRequestsGreaterThanOne: false\n    resources:\n      - name: nvidia.com/gpu\n        replicas: 3'"
    "--set-json nodeSelector='{\"feature.node.kubernetes.io/pci-10de.present\":\"true\"}'"
  ];

  preDeploy = ''
    # RuntimeClass for nvidia
    log nvidia "Creating RuntimeClass nvidia"
    cat <<'EOF' | ${kubectl} apply -f -
    apiVersion: node.k8s.io/v1
    kind: RuntimeClass
    metadata:
      name: nvidia
    handler: nvidia
    EOF
  '';
in
  lib.mkIf (isInit && isMaster && hasNvidiaGpu) {
    systemd.services.deploy-nvidia-device-plugin = mkHelmService {
      after = ["helm-deploy-cilium.service"];
      name = "NVIDIA Device Plugin";
      release = "nvidia-device-plugin";
      namespace = "kube-system";
      chart = "nvdp/nvidia-device-plugin";
      version = versions.nvidiaDevicePlugin;
      extraArgs = devicePluginArgs;
      inherit preDeploy;
      postDeploy = ''
        ${kubectl} rollout status daemonset nvidia-device-plugin -n kube-system --timeout=120s
      '';
    };
  }
