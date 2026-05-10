{
  lib,
  clusterConfig,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService;
  isInit = nodeConfig.init;
in
  lib.mkIf (clusterConfig.storageBackend == "longhorn") {
    systemd.services.helm-deploy-longhorn = lib.mkIf isInit (mkHelmService {
      name = "Longhorn Storage";
      release = "longhorn";
      namespace = "longhorn-system";
      chart = "longhorn/longhorn";
      version = versions.longhorn;
      extraArgs = [
        "--set defaultSettings.defaultDataPath=/data" # matches disko 'data' role mountpoint
        "--set defaultSettings.defaultReplicaCount=2"
        "--set persistence.defaultClassReplicaCount=2"
        "--set csi.attacherReplicaCount=2"
        "--set csi.provisionerReplicaCount=2"
        "--set csi.resizerReplicaCount=2"
        "--set csi.snapshotterReplicaCount=2"
        "--set longhornManager.resources.limits.cpu=500m"
        "--set longhornManager.resources.limits.memory=1Gi"
        "--set longhornManager.resources.requests.cpu=100m"
        "--set longhornManager.resources.requests.memory=128Mi"
        "--set longhornUI.replicas=1"
        "--set longhornUI.resources.limits.cpu=200m"
        "--set longhornUI.resources.limits.memory=256Mi"
        "--set longhornUI.resources.requests.cpu=50m"
        "--set longhornUI.resources.requests.memory=64Mi"
        "--set csi.attacher.resources.limits.cpu=200m"
        "--set csi.attacher.resources.limits.memory=256Mi"
        "--set csi.attacher.resources.requests.cpu=50m"
        "--set csi.attacher.resources.requests.memory=64Mi"
        "--set csi.provisioner.resources.limits.cpu=200m"
        "--set csi.provisioner.resources.limits.memory=256Mi"
        "--set csi.provisioner.resources.requests.cpu=50m"
        "--set csi.provisioner.resources.requests.memory=64Mi"
        "--set csi.resizer.resources.limits.cpu=200m"
        "--set csi.resizer.resources.limits.memory=256Mi"
        "--set csi.resizer.resources.requests.cpu=50m"
        "--set csi.resizer.resources.requests.memory=64Mi"
        "--set csi.snapshotter.resources.limits.cpu=200m"
        "--set csi.snapshotter.resources.limits.memory=256Mi"
        "--set csi.snapshotter.resources.requests.cpu=50m"
        "--set csi.snapshotter.resources.requests.memory=64Mi"
        "--set csi.driver.resources.limits.cpu=300m"
        "--set csi.driver.resources.limits.memory=512Mi"
        "--set csi.driver.resources.requests.cpu=50m"
        "--set csi.driver.resources.requests.memory=64Mi"
        "--set longhornDriverDeployer.resources.limits.cpu=200m"
        "--set longhornDriverDeployer.resources.limits.memory=256Mi"
        "--set longhornDriverDeployer.resources.requests.cpu=50m"
        "--set longhornDriverDeployer.resources.requests.memory=64Mi"
        "--set defaultSettings.guaranteedInstanceManagerCPU=500m"
        "--set defaultSettings.guaranteedInstanceManagerMemory=1536Mi"
        "--set defaultSettings.guaranteedEngineManagerCPU=500m"
        "--set defaultSettings.guaranteedEngineManagerMemory=1536Mi"
        "--set defaultSettings.guaranteedEngineCPU=500m"
        "--set defaultSettings.guaranteedEngineMemory=512Mi"
        "--set defaultSettings.guaranteedShareManagerCPU=200m"
        "--set defaultSettings.guaranteedShareManagerMemory=512Mi"
        # Homelab tuning
        "--set defaultSettings.replicaAutoBalance=least-effort"
        "--set defaultSettings.storageOverProvisioningPercentage=100"
        "--set defaultSettings.defaultDataLocality=best-effort"
        "--set defaultSettings.allowRecurringJobWhileVolumeDetached=true"
      ];
    });
  }
