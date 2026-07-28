{
  lib,
  clusterConfig,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService mkResourceArgs;
  isInit = nodeConfig.init;
in
  lib.mkIf (clusterConfig.storageBackend == "longhorn") {
    systemd.services.helm-deploy-longhorn = lib.mkIf isInit (mkHelmService {
      after = ["helm-deploy-cilium.service"];
      name = "Longhorn Storage";
      release = "longhorn";
      namespace = "longhorn-system";
      chart = "longhorn/longhorn";
      version = versions.longhorn;
      extraArgs =
        [
          "--set defaultSettings.defaultDataPath=/data" # matches disko 'data' role mountpoint
          "--set defaultSettings.defaultReplicaCount=2"
          "--set persistence.defaultClassReplicaCount=2"
          "--set csi.attacherReplicaCount=2"
          "--set csi.provisionerReplicaCount=2"
          "--set csi.resizerReplicaCount=2"
          "--set csi.snapshotterReplicaCount=2"
          "--set longhornUI.replicas=1"
        ]
        ++ mkResourceArgs "longhornManager" {
          cpu = "500m";
          memory = "1Gi";
        } {
          cpu = "100m";
          memory = "128Mi";
        }
        ++ mkResourceArgs "longhornUI" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "csi.attacher" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "csi.provisioner" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "csi.resizer" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "csi.snapshotter" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "csi.driver" {
          cpu = "300m";
          memory = "512Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ mkResourceArgs "longhornDriverDeployer" {
          cpu = "200m";
          memory = "256Mi";
        } {
          cpu = "50m";
          memory = "64Mi";
        }
        ++ [
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
