{
  lib,
  clusterConfig,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService kubectl;

  isInit = nodeConfig.init;
  apiPort = toString clusterConfig.network.apiServerPort;
  ciliumMTU = toString (clusterConfig.network.wgMTU - 50); # 1440 − 50 for Geneve encapsulation

  ciliumArgs = [
    "--set operator.replicas=1"
    "--set kubeProxyReplacement=true"
    "--set k8sServiceHost=${nodeConfig.network.wgIP}"
    "--set k8sServicePort=${apiPort}"
    "--set operator.k8sServiceHost=${nodeConfig.network.wgIP}"
    "--set operator.k8sServicePort=${apiPort}"
    "--set ipam.mode=kubernetes"
    "--set ipam.operator.clusterPoolIPv4PodCIDR=${clusterConfig.network.podCIDR}"
    "--set routingMode=tunnel"
    "--set tunnelProtocol=geneve"
    "--set bpf.masquerade=true"
    "--set enableIPv4Masquerade=true"
    "--set nodePort.enabled=true" # required for kube-vip LoadBalancer with externalTrafficPolicy=Local
    "--set l7Proxy=false"
    "--set mtu=${ciliumMTU}"
    "--set encryption.enabled=false"
    "--set hubble.enabled=false"
    "--set prometheus.enabled=false"
    "--set operator.resources.limits.cpu=200m"
    "--set operator.resources.limits.memory=256Mi"
    "--set operator.resources.requests.cpu=50m"
    "--set operator.resources.requests.memory=64Mi"
    "--set resources.limits.cpu=500m"
    "--set resources.limits.memory=512Mi"
    "--set resources.requests.cpu=100m"
    "--set resources.requests.memory=128Mi"
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
  });
}
