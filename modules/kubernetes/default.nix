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
  isLxc = nodeConfig.platform == "lxc";
  hasNvidiaGpu = nodeConfig.gpu.enable && nodeConfig.gpu.vendor == "nvidia";
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
      ++ lib.optionals isLxc [
        "--node-label=node.kubernetes.io/instance-type=lxc"
      ]
      ++ lib.optionals hasNvidiaGpu [
        "--node-label=nvidia.com/gpu.present=true"
        "--node-label=feature.node.kubernetes.io/pci-10de.present=true"
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

  environment.systemPackages = with pkgs;
    [
      cilium-cli
      cni-plugins
      k9s
      kubectl
      kubernetes-helm
      util-linux
    ]
    ++ lib.optionals (clusterConfig.storageBackend == "longhorn") [
      openiscsi
      xfsprogs
    ]
    ++ lib.optionals hasNvidiaGpu [nvidia-container-toolkit];

  services.openiscsi = lib.mkIf (clusterConfig.storageBackend == "longhorn") {
    enable = true;
    name = "${wgIP}-iscsi";
  };

  systemd.services.iscsid = lib.mkIf (clusterConfig.storageBackend == "longhorn") {
    wantedBy = ["multi-user.target"];
    before = ["k3s.service"];
  };

  boot.kernelModules = lib.optionals (!isLxc) [
    "iscsi_tcp"
    "dm_snapshot"
    "dm_mirror"
    "dm_thin_pool"
  ];

  systemd.tmpfiles.rules =
    [
      "L+ /usr/bin/nsenter  - - - - /run/current-system/sw/bin/nsenter"
      "d  /opt/cni/bin 0755 root root -"
    ]
    ++ lib.optionals (clusterConfig.storageBackend == "longhorn") [
      "L+ /usr/bin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
      "L+ /sbin/blkid      - - - - /run/current-system/sw/bin/blkid"
    ];

  systemd.services.lxc-storage-preflight = lib.mkIf (isLxc && hasStorage && storageBackend == "longhorn") {
    description = "Verify host-provided LXC storage";
    before = ["k3s.service"];
    requiredBy = ["k3s.service"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.util-linux}/bin/mountpoint --quiet /data";
      RemainAfterExit = true;
    };
  };

  systemd.services.lxc-kubernetes-preflight = lib.mkIf isLxc {
    description = "Verify LXC Kubernetes host features";
    before = ["k3s.service"];
    requiredBy = ["k3s.service"];
    script = ''
      test "$(${pkgs.coreutils}/bin/stat -fc %T /sys/fs/cgroup)" = cgroup2fs
      ${pkgs.util-linux}/bin/mountpoint --quiet /sys/fs/bpf
      ${pkgs.gnugrep}/bin/grep --quiet --word-regexp overlay /proc/filesystems || {
        echo "Kubernetes on LXC requires overlayfs loaded on the host" >&2
        exit 1
      }
      cap_bnd="$(${pkgs.gawk}/bin/awk '/^CapBnd:/ { print $2 }' /proc/1/status)"
      if (( ! (16#$cap_bnd & 1 << 16) )); then
        echo "Kubernetes on LXC requires SYS_MODULE in the capability bounding set" >&2
        exit 1
      fi
      case ",$(${pkgs.util-linux}/bin/findmnt -T /proc/sys/vm/overcommit_memory -no OPTIONS)," in
        *,rw,*) ;;
        *)
          echo "Kubernetes on LXC requires a writable /proc/sys" >&2
          exit 1
          ;;
      esac
      test -c /dev/kmsg || {
        echo "Kubernetes on LXC requires the host /dev/kmsg device" >&2
        exit 1
      }
      ${lib.optionalString (storageBackend == "longhorn") ''
        test "$(ulimit -l)" = unlimited || {
          echo "Longhorn on LXC requires lxc.prlimit.memlock: unlimited" >&2
          exit 1
        }
      ''}
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  systemd.services.lxc-nvidia-preflight = lib.mkIf (isLxc && hasNvidiaGpu) {
    description = "Verify host-provided NVIDIA devices";
    before = ["k3s.service"];
    requiredBy = ["k3s.service"];
    script = ''
      test -c /dev/nvidiactl
      test -c /dev/nvidia0
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  # Multus executes CNI plugins from inside its daemon container. Real files
  # keep /opt/cni/bin usable there without mounting /nix/store.
  system.activationScripts.cniPlugins.text = ''
    install -d -m 0755 /opt/cni/bin
    for plugin in bridge host-local loopback; do
      rm -f "/opt/cni/bin/$plugin"
      install -m 0755 "${pkgs.cni-plugins}/bin/$plugin" "/opt/cni/bin/$plugin"
    done
  '';

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
