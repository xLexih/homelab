# k3s server/agent without its own networking: Cilium (cilium.nix) provides
# the pod network, Services and network policy. Every server carries the same
# add-on charts in its manifest directory, so any live server reconciles
# them; charts are fetched at build time and served from the node.
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
  # Joining nodes resolve this name to the other servers, `init` first, and
  # connect to the first that accepts, so any live server can admit new nodes.
  # A server that answers but has not joined itself yet blocks the join, hence
  # the fixed order.
  joinName = "api.${cluster.name}.internal";
  joinVia = lib.filter (n: lib.elem "server" n.roles && n.name != node.name) (
    [cluster.nodes.${cluster.init}] ++ lib.filter (n: n.name != cluster.init) nodes
  );
  package =
    pkgs."k3s_${builtins.replaceStrings ["."] ["_"] cluster.k3sVersion}"
    or (throw "k3sVersion ${cluster.k3sVersion} is not in this nixpkgs; available: ${toString (builtins.filter (lib.hasPrefix "k3s_1_") (builtins.attrNames pkgs))}");

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
            # shown to kubectl users; there is no audit log to write to
            warn = "restricted";
            warn-version = "latest";
          };
          exemptions.namespaces = ["kube-system" "longhorn-system"];
        };
      }
    ];
  };

  # The k3s module links manifests into place but never removes the links of
  # ones dropped from the configuration, and k3s keeps applying those (a
  # removed chart comes back on the next k3s start). Its resources stay
  # either way: `kubectl delete helmchart <name>` uninstalls a chart.
  manifests = config.services.k3s.autoDeployCharts // config.services.k3s.manifests;
  kept = map (m: m.target) (lib.attrValues (lib.filterAttrs (_: m: m.enable) manifests));
  pruneManifests = pkgs.writeShellScript "k3s-prune-manifests" ''
    for f in /var/lib/rancher/k3s/server/manifests/*; do
      [[ -L $f && $(readlink "$f") == /nix/store/* ]] || continue
      case " ${toString kept} " in *" ''${f##*/} "*) continue ;; esac
      echo "removing ''${f##*/}: no longer in the configuration"
      rm -f "$f"
    done
  '';
in {
  assertions = [
    {
      assertion = s3 == null || builtins.pathExists (secrets + "/etcd-s3.age");
      message = "etcdS3 is set but secrets/etcd-s3.age is missing: nix run .#${cluster.name} -- secrets edit etcd-s3.age";
    }
  ];

  age.secrets.k3s-token.file = secrets + "/k3s-token.age";
  age.secrets.etcd-s3 = lib.mkIf (isServer && s3 != null) {file = secrets + "/etcd-s3.age";};

  # fs.inotify limits are global: set in vm.nix, or on the host for LXC.
  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

  systemd.services.k3s = {
    wants = ["wireguard-wg0.service"];
    after = ["wireguard-wg0.service"];
    # glibc reorders /etc/hosts answers by address prefix (RFC 6724); Go's own
    # resolver keeps the file order.
    environment.GODEBUG = "netdns=go";
    serviceConfig.ExecStartPre = lib.optional isServer "${pruneManifests}";
    # containerd reads registries.yaml only when k3s starts
    restartTriggers = lib.optional (cluster.registries != {}) config.environment.etc."rancher/k3s/registries.yaml".source;
  };

  environment.etc."rancher/k3s/registries.yaml" = lib.mkIf (cluster.registries != {}) {
    text = builtins.toJSON cluster.registries;
  };

  # `kubectl` without sudo on servers. wheel (admin) already has passwordless
  # sudo, so reading the cluster-admin kubeconfig grants nothing new. Agents
  # have no admin kubeconfig.
  environment.variables.KUBECONFIG = lib.mkIf isServer "/etc/rancher/k3s/k3s.yaml";

  networking.extraHosts = lib.concatMapStrings (n: "${n.wgIP} ${joinName}\n") joinVia;

  services.k3s = {
    enable = true;
    inherit package;
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
    disable = lib.optionals isServer (["traefik" "coredns" "servicelb"] ++ lib.optional hasStorage "local-storage");

    extraFlags =
      [
        # Memory and CPU pods cannot take from the OS and k3s itself.
        "--kubelet-arg=system-reserved=${
          if isServer
          then cluster.reserved.server
          else cluster.reserved.agent
        }"
      ]
      ++ lib.optionals isServer [
        "--flannel-backend=none"
        "--disable-network-policy"
        "--disable-kube-proxy"
        "--bind-address=${node.wgIP}"
        "--write-kubeconfig-group=wheel"
        "--write-kubeconfig-mode=0640"
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
    # Not named "coredns": k3s always writes its own manifests/coredns.yaml,
    # even when disabled, and fails if that file is our read-only chart.
    autoDeployCharts.cluster-dns = lib.mkIf isServer {
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
        # Never both replicas on one node (the second waits for another node
        # while the cluster grows), and leave a failed node after 30 s
        # instead of 300 s.
        affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution = [
          {
            topologyKey = "kubernetes.io/hostname";
            labelSelector.matchLabels."k8s-app" = "kube-dns";
          }
        ];
        tolerations = map (key: {
          inherit key;
          operator = "Exists";
          effect = "NoExecute";
          tolerationSeconds = 30;
        }) ["node.kubernetes.io/not-ready" "node.kubernetes.io/unreachable"];
      };
    };
  };
}
