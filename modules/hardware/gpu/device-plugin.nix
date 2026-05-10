# modules/hardware/gpu/device-plugin.nix
{
  lib,
  helpers,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService kubectl;

  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;

  gpuCfg = nodeConfig.gpu;
  hasNvidiaGpu = gpuCfg.enable && gpuCfg.vendor == "nvidia";

  # https://github.com/NixOS/nixpkgs/issues/288037#issuecomment-4401306177
  devicePluginArgs = [
    "--set image.repository=nvcr.io/nvidia/k8s-device-plugin"
    "--set image.tag=v${versions.nvidiaDevicePlugin}"
    # Required for GFD to work properly                                                                                                                                      Amount of vGpus (3 cuz i have 6gb card lol)
    "--set runtimeClassName=nvidia"
    # https://github.com/UntouchedWagons/K3S-NVidia/blob/main/values.yaml
    "--set config.map.default='version: v1\nflags:\n  migStrategy: none\nsharing:\n  timeSlicing:\n    renameByDefault: false\n    failRequestsGreaterThanOne: false\n    resources:\n      - name: nvidia.com/gpu\n        replicas: 3'"
    "--set-json nodeSelector='{\"feature.node.kubernetes.io/pci-10de.present\":\"true\"}'"
  ];

  preDeploy = ''
    # Label the GPU node
    NODE_NAME=$(cat /proc/sys/kernel/hostname)
    log nvidia "Labeling node $NODE_NAME for GPU scheduling"
    for i in {1..30}; do
      ${kubectl} get node "$NODE_NAME" &>/dev/null && break
      sleep 2
    done

    ${kubectl} label node "$NODE_NAME" \
      nvidia.com/gpu.present=true \
      feature.node.kubernetes.io/pci-10de.present=true \
      --overwrite
    log nvidia "Node labels applied"

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
      name = "NVIDIA Device Plugin";
      release = "nvidia-device-plugin";
      namespace = "kube-system";
      chart = "nvdp/nvidia-device-plugin";
      version = versions.nvidiaDevicePlugin;
      extraArgs = devicePluginArgs;
      inherit preDeploy;
      postDeploy = ''
        ${kubectl} rollout status daemonset nvidia-device-plugin -n kube-system --timeout=120s || \
          echo "[nvidia-device-plugin] Not ready yet (will retry on next boot)"
      '';
    };
  }
