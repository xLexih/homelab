# k3s server/agent. Networking, network policy and metrics are the components
# embedded in k3s (flannel over wg0, kube-proxy, kube-router policy,
# metrics-server). Every server carries the same add-on charts in its manifest
# directory, so any live server reconciles them; charts are fetched at build
# time and served from the node.
{
  lib,
  pkgs,
  config,
  cluster,
  node,
  secrets,
  ...
}: let
  ip = import ../lib/ip.nix lib;
  net = cluster.network;
  isServer = lib.elem "server" node.roles;
  isInit = node.name == cluster.init;
  nodes = lib.attrValues cluster.nodes;
  hasStorage = lib.any (n: lib.elem "storage" n.roles) nodes;
  s3 = cluster.etcdS3;
  dnsIP = ip.host net.serviceCIDR 10;
  dnsReplicas = lib.min 2 (builtins.length nodes);
  # Joining nodes resolve this name to every other server and use the first
  # that answers, so any live server can admit new nodes.
  joinName = "api.${cluster.name}.internal";
  otherServers = lib.filter (n: lib.elem "server" n.roles && n.name != node.name) nodes;

  podSecurity = (pkgs.formats.json {}).generate "pod-security.json" {
    apiVersion = "apiserver.config.k8s.io/v1";
    kind = "AdmissionConfiguration";
    plugins = [
      {
        name = "PodSecurity";
        configuration = {
          apiVersion = "pod-security.admission.config.k8s.io/v1";
          kind = "PodSecurityConfiguration";
          defaults = {
            enforce = "baseline";
            enforce-version = "latest";
            warn = "restricted";
            warn-version = "latest";
            audit = "restricted";
            audit-version = "latest";
          };
          exemptions.namespaces = ["kube-system" "longhorn-system" "metallb-system"];
        };
      }
    ];
  };
in {
  assertions = [
    {
      assertion = s3 == null || builtins.pathExists (secrets + "/etcd-s3.age");
      message = "etcdS3 is set but secrets/etcd-s3.age is missing: nix run .#${cluster.name} -- secrets edit etcd-s3.age";
    }
  ];

  age.secrets.k3s-token.file = secrets + "/k3s-token.age";
  age.secrets.etcd-s3 = lib.mkIf (isServer && s3 != null) {file = secrets + "/etcd-s3.age";};

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 524288;
  };

  systemd.services.k3s = {
    wants = ["wireguard-wg0.service"];
    after = ["wireguard-wg0.service"];
  };

  networking.hosts = lib.listToAttrs (map (n: lib.nameValuePair n.wgIP [joinName]) otherServers);

  services.k3s = {
    enable = true;
    role =
      if isServer
      then "server"
      else "agent";
    clusterInit = isInit;
    serverAddr = lib.optionalString (!isInit) "https://${joinName}:6443";
    tokenFile = config.age.secrets.k3s-token.path;
    nodeIP = node.wgIP;
    nodeExternalIP = node.ip;
    nodeLabel =
      ["topology.kubernetes.io/zone=${node.location}"]
      ++ lib.optional (lib.elem "storage" node.roles) "node.longhorn.io/create-default-disk=true"
      ++ lib.optional (lib.elem "gpu" node.roles) "nvidia.com/gpu.present=true";
    gracefulNodeShutdown.enable = true;
    environmentFile = lib.mkIf (isServer && s3 != null) config.age.secrets.etcd-s3.path;
    disable = lib.optionals isServer (["traefik" "coredns"] ++ lib.optional hasStorage "local-storage");

    extraFlags =
      [
        "--flannel-iface=wg0"
        # NodePorts stay on the mesh; publish services with type LoadBalancer.
        "--kube-proxy-arg=nodeport-addresses=${net.wgCIDR}"
      ]
      ++ lib.optionals isServer [
        "--bind-address=${node.wgIP}"
        "--advertise-address=${node.wgIP}"
        "--tls-san=127.0.0.1"
        "--tls-san=${joinName}"
        "--cluster-cidr=${net.podCIDR}"
        "--service-cidr=${net.serviceCIDR}"
        "--cluster-dns=${dnsIP}"
        "--secrets-encryption"
        "--kube-apiserver-arg=admission-control-config-file=${podSecurity}"
        "--etcd-snapshot-retention=14"
      ]
      ++ lib.optionals (isServer && s3 != null) [
        "--etcd-s3"
        "--etcd-s3-endpoint=${s3.endpoint}"
        "--etcd-s3-bucket=${s3.bucket}"
        "--etcd-s3-region=${s3.region}"
        "--etcd-s3-folder=${cluster.name}"
      ];

    # CoreDNS from the upstream chart: k3s ships a single replica.
    autoDeployCharts.coredns = lib.mkIf isServer {
      name = "coredns";
      repo = "https://coredns.github.io/helm";
      version = "1.48.1";
      hash = "sha256-i1JZEndjCJgdZak5SzCBQ4WpHhmEub5HD/xtyOhl8t8=";
      targetNamespace = "kube-system";
      extraFieldDefinitions.spec.failurePolicy = "abort";
      values = {
        fullnameOverride = "coredns";
        k8sAppLabelOverride = "kube-dns";
        replicaCount = dnsReplicas;
        priorityClassName = "system-cluster-critical";
        service = {
          name = "kube-dns";
          clusterIP = dnsIP;
        };
        podDisruptionBudget = lib.optionalAttrs (dnsReplicas > 1) {maxUnavailable = 1;};
        topologySpreadConstraints = [
          {
            maxSkew = 1;
            topologyKey = "kubernetes.io/hostname";
            whenUnsatisfiable = "ScheduleAnyway";
            labelSelector.matchLabels."k8s-app" = "kube-dns";
          }
        ];
      };
    };
  };
}
