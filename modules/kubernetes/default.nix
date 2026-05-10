# modules/kubernetes/default.nix
{
  config,
  lib,
  pkgs,
  clusterConfig,
  helpers,
  nodeConfig,
  ...
}: let
  inherit (helpers) hasRole initNode;

  isInit = nodeConfig.init;
  isMaster = hasRole "master" nodeConfig;
  hasStorage = hasRole "storage" nodeConfig;
  wgIP = nodeConfig.network.wgIP;

  registryCfg = clusterConfig.registry;
  storageBackend = clusterConfig.storageBackend;

  # CoreDNS service IP (10th address of the service CIDR, k3s default)
  clusterDNS = let
    octets = builtins.match "^([0-9]+)\\.([0-9]+)\\.([0-9]+)\\.[0-9]+/[0-9]+$" clusterConfig.network.serviceCIDR;
  in
    if octets != null
    then "${builtins.elemAt octets 0}.${builtins.elemAt octets 1}.${builtins.elemAt octets 2}.10"
    else throw "Invalid serviceCIDR format: ${clusterConfig.network.serviceCIDR}";

  serverAddr =
    if isInit
    then null
    else "https://${clusterConfig.nodes.${initNode}.network.wgIP}:${toString clusterConfig.network.apiServerPort}";

  gpuEnabled = nodeConfig.gpu.enable;
  nvidiaRuntimeBinary = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime.cdi";

  containerdConfig =
    ''
      {{ template "base" . }}
    ''
    + lib.optionalString gpuEnabled ''
      # https://github.com/NixOS/nixpkgs/issues/288037#issuecomment-3835275473
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
        privileged_without_host_devices = false
        runtime_engine = ""
        runtime_root = ""
        runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
        BinaryName = "${nvidiaRuntimeBinary}"
    '';
in {
  imports = [
    ./etcd-backup.nix
    ./helm.nix
    ./coredns.nix
  ];

  age.secrets.k3s-token.file = ../../secrets/k3s-token.age;

  services.k3s = {
    enable = true;
    role =
      if isMaster
      then "server"
      else "agent";
    tokenFile = config.age.secrets.k3s-token.path;
    serverAddr = lib.mkIf (!isInit) serverAddr;
    containerdConfigTemplate = containerdConfig;
    extraFlags =
      [
        "--node-ip=${wgIP}"
        "--node-label=topology.kubernetes.io/zone=${nodeConfig.location}"
        "--node-label=fabric=wireguard"
      ]
      ++ lib.optionals isMaster [
        "--bind-address=${wgIP}"
        "--advertise-address=${wgIP}"
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
        "--disable=traefik"
        "--disable=servicelb"
        "--cluster-cidr=${clusterConfig.network.podCIDR}"
        "--service-cidr=${clusterConfig.network.serviceCIDR}"
        "--cluster-dns=${clusterDNS}"
        "--tls-san=${wgIP}"
        "--tls-san=127.0.0.1"
        "--etcd-snapshot-retention=${toString clusterConfig.etcdSnapshotRetention}"
      ]
      ++ lib.optionals isInit ["--cluster-init"]
      ++ lib.optionals (isMaster && storageBackend == "longhorn") ["--disable=local-storage"]
      ++ lib.optionals hasStorage ["--node-label=node.longhorn.io/create-default-disk=true"]
      ++ lib.optionals (isMaster && registryCfg.type == "k3s") ["--embedded-registry"];
  };

  environment.etc."rancher/k3s/registries.yaml" = lib.mkIf (registryCfg.type == "docker") {
    text = ''
      mirrors:
        "registry-docker-registry.registry.svc.cluster.local:5000":
          endpoint:
            - "${
        if registryCfg.http
        then "http"
        else "https"
      }://registry-docker-registry.registry.svc.cluster.local:5000"
    '';
  };

  networking.nameservers = [clusterDNS] ++ clusterConfig.network.nameservers;
  networking.search =
    []
    ++ lib.optional (registryCfg.type == "docker") "registry.svc.cluster.local"
    ++ ["svc.cluster.local" "cluster.local"];

  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";

  environment.systemPackages = with pkgs; [
    cilium-cli
    k9s
    kubectl
    kubernetes-helm
    openiscsi
    util-linux
    xfsprogs
  ];

  services.openiscsi = {
    enable = true;
    name = "${wgIP}-iscsi";
  };

  systemd.services.iscsid = {
    wantedBy = ["multi-user.target"];
    before = ["k3s.service"];
  };

  boot.kernelModules = [
    "iscsi_tcp"
    "dm_snapshot"
    "dm_mirror"
    "dm_thin_pool"
  ];

  systemd.tmpfiles.rules = [
    "L+ /usr/bin/nsenter  - - - - /run/current-system/sw/bin/nsenter"
    "L+ /usr/bin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
    "L+ /sbin/blkid      - - - - /run/current-system/sw/bin/blkid"
  ];

  systemd.services.k3s.serviceConfig = {
    MemoryMax = "3G";
    MemoryHigh = "2.5G";
    CPUQuota = "200%";
    Nice = -5;
    IOWeight = 1000;
    # Ensure the nvidia runtime binary is visible to k3s
    Environment = lib.mkIf gpuEnabled [
      "PATH=/run/current-system/sw/bin:/usr/local/bin:/nix/var/nix/profiles/default/bin"
    ];
  };
}
