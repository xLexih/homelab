{
  lib,
  clusterConfig,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService mkResourceArgs kubectl;

  isInit = nodeConfig.init;
  apiPort = toString clusterConfig.network.apiServerPort;
  ciliumMTU = toString clusterConfig.network.wgMTU;

  ciliumArgs = [
    "--set operator.replicas=1"
    "--set kubeProxyReplacement=true"
    "--set k8sServiceHost=${nodeConfig.network.wgIP}"
    "--set k8sServicePort=${apiPort}"
    "--set operator.k8sServiceHost=${nodeConfig.network.wgIP}"
    "--set operator.k8sServicePort=${apiPort}"
    "--set ipam.mode=kubernetes"
    "--set ipam.operator.clusterPoolIPv4PodCIDR=${clusterConfig.network.podCIDR}"
    "--set cni.exclusive=false" # Octelium requires Multus to coexist with the primary CNI
    "--set cni.customConf=true" # Multus owns /etc/cni/net.d as the primary CNI entrypoint
    "--set cni.write-cni-conf-when-ready=/etc/cni/net.d/05-cilium.conflist" # ensure primary CNI config exists for Multus
    "--set routingMode=native"
    "--set tunnelProtocol=geneve"
    "--set ipv4NativeRoutingCIDR=${clusterConfig.network.podCIDR}"
    "--set autoDirectNodeRoutes=false"
    "--set bpf.masquerade=true"
    "--set enableIPv4Masquerade=true"
    "--set nodePort.enabled=true" # required for kube-vip LoadBalancer with externalTrafficPolicy=Local
    "--set l7Proxy=false"
    "--set mtu=${ciliumMTU}"
    "--set encryption.enabled=false"
    "--set hubble.enabled=false"
    "--set prometheus.enabled=false"
  ] ++ mkResourceArgs "operator" { cpu = "200m"; memory = "256Mi"; } { cpu = "50m"; memory = "64Mi"; }
  ++ mkResourceArgs "" { cpu = "500m"; memory = "512Mi"; } { cpu = "100m"; memory = "128Mi"; }
  ++ [
    "--set loadBalancer.mode=hybrid" # TCP DSR, UDP SNAT — compatible with kube-vip ARP
    "--set loadBalancer.dsrDispatch=geneve" # tunnel DSR replies over Geneve
  ];

  ciliumPostDeploy = ''
    ${kubectl} rollout status daemonset cilium -n kube-system --timeout=300s
    cat <<EOF | ${kubectl} apply -f -
    apiVersion: policy/v1
    kind: PodDisruptionBudget
    metadata:
      name: cilium-operator
      namespace: kube-system
    spec:
      minAvailable: 1
      selector:
        matchLabels:
          io.cilium/app: operator
    EOF
  '';
in {
  systemd.services.helm-deploy-cilium = lib.mkIf isInit (mkHelmService {
    name = "Cilium CNI";
    release = "cilium";
    namespace = "kube-system";
    chart = "cilium/cilium";
    version = versions.cilium;
    extraArgs = ciliumArgs;
    postDeploy = ciliumPostDeploy;
    before = ["helm-deploy-kube-vip.service" "helm-deploy-longhorn.service" "deploy-nvidia-device-plugin.service"];
  });
}
