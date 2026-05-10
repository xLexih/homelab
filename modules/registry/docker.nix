{
  lib,
  clusterConfig,
  helpers,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService kubectl;

  registryCfg = clusterConfig.registry;
  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;

  shouldDeploy = isInit && isMaster && registryCfg.type == "docker" && clusterConfig.storageBackend == "longhorn";

  registryArgs = [
    "--set persistence.enabled=true"
    "--set persistence.size=${registryCfg.storageSize}"
    "--set persistence.storageClass=longhorn-rwx"
    "--set persistence.accessMode=ReadWriteMany"
    "--set replicaCount=${toString registryCfg.replicas}"
    "--set service.type=ClusterIP"
    "--set service.port=5000"
    "--set resources.limits.cpu=500m"
    "--set resources.limits.memory=512Mi"
    "--set resources.requests.cpu=100m"
    "--set resources.requests.memory=128Mi"
    # Spread replicas across nodes to avoid SPOF
    "--set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].weight=100"
    "--set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.labelSelector.matchLabels.app=docker-registry"
    "--set affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution[0].podAffinityTerm.topologyKey=kubernetes.io/hostname"
  ];

  registryPreDeploy = ''
    log registry "Waiting for Longhorn CSI..."
    until ${kubectl} get csinodes -o jsonpath='{range .items[*]}{range .spec.drivers[*]}{.name}{" "}{end}{end}' 2>/dev/null | grep -q "driver.longhorn.io"; do
      sleep 5
    done
  '';

  registryUIArgs = [
    "--set replicaCount=${toString registryCfg.replicas}"
    "--set service.type=ClusterIP"
    "--set service.port=80"
    "--set env.REGISTRY_TITLE='Cluster Registry'"
    "--set env.REGISTRY_URL='http://registry-docker-registry.registry.svc.cluster.local:5000'"
    "--set env.SINGLE_REGISTRY=true"
    "--set env.SHOW_CONTENT_DIGEST=true"
    "--set env.DELETE_IMAGES=true"
    "--set resources.limits.cpu=200m"
    "--set resources.limits.memory=256Mi"
    "--set resources.requests.cpu=50m"
    "--set resources.requests.memory=64Mi"
  ];
in
  lib.mkIf shouldDeploy {
    # RWX storage class required for multi-replica Docker registry
    systemd.services.registry-rwx-storageclass = {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5m";
      };
      script = ''
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        cat <<EOF | ${kubectl} apply -f -
        apiVersion: storage.k8s.io/v1
        kind: StorageClass
        metadata:
          name: longhorn-rwx
          annotations:
            storageclass.kubernetes.io/is-default-class: "false"
        provisioner: driver.longhorn.io
        allowVolumeExpansion: true
        reclaimPolicy: Delete
        volumeBindingMode: Immediate
        parameters:
          numberOfReplicas: "2"
          dataLocality: "disabled"
          accessMode: "rwx"
        EOF
      '';
    };

    systemd.services.helm-deploy-registry = mkHelmService {
      name = "Docker Registry";
      release = "registry";
      namespace = "registry";
      chart = "twuni/docker-registry";
      version = versions.dockerRegistry;
      extraArgs = registryArgs;
      preDeploy = registryPreDeploy;
    };

    systemd.services.helm-deploy-registry-ui = lib.mkIf registryCfg.enableUI (mkHelmService {
      name = "Docker Registry UI";
      release = "registry-ui";
      namespace = "registry";
      chart = "joxit/docker-registry-ui";
      version = versions.dockerRegistryUI;
      extraArgs = registryUIArgs;
    });
  }
