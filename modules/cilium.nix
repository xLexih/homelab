# Cilium: pod network, Services (eBPF instead of kube-proxy) and network
# policy. Pods talk over Geneve tunnels between the nodes' WireGuard
# addresses, so wg0 encrypts them and its peers only route /32s.
#
# k3s runs without flannel, kube-proxy and kube-router; every server carries
# the chart and its helm-controller installs it as a bootstrap chart, whose
# job runs on the host network before any pod network exists.
{
  lib,
  cluster,
  node,
  ...
}: let
  nodes = lib.attrValues cluster.nodes;
  servers = lib.filter (n: lib.elem "server" n.roles) nodes;
  net = cluster.network;
  lbIPAM = cluster.loadBalancerIPs != [];
in
  lib.mkIf (lib.elem "server" node.roles) {
    services.k3s.autoDeployCharts.cilium = {
      name = "cilium";
      repo = "https://helm.cilium.io";
      version = "1.20.2";
      hash = "sha256-sq/Ye391+HX5KhRVnxT1m3uru0edlo4/1iWiC/MOwg4=";
      targetNamespace = "kube-system";
      extraFieldDefinitions.spec = {
        bootstrap = true;
        failurePolicy = "abort";
      };
      values =
        {
          # Agents start before any Service works: give them every server.
          k8s.apiServerURLs = toString (map (n: "https://${n.wgIP}:6443") servers);
          kubeProxyReplacement = true;
          # LAN interfaces carry LoadBalancer traffic; NodePorts listen only
          # on wg0, as LoadBalancer addresses are the way into the cluster.
          devices = lib.unique (map (n: n.interface) nodes) ++ ["wg0"];
          nodePort.addresses = [net.wgCIDR];
          # NetworkPolicy ipBlocks may select nodes, e.g. the API servers.
          policyCIDRMatchMode = ["nodes"];
          ipam.mode = "kubernetes";
          routingMode = "tunnel";
          tunnelProtocol = "geneve";
          # Cilium subtracts the Geneve header itself.
          MTU = net.wgMTU;
          bpf = {
            masquerade = true;
            # `service.cilium.io/forwarding-mode: snat` per Service
            lbModeAnnotation = true;
          };
          # Backends answer clients directly, so pods see the client's
          # address. The reply leaves the backend's node: keep a Service's
          # pods in the location of its address, or annotate it `snat`.
          loadBalancer = {
            mode = "dsr";
            dsrDispatch = "geneve";
          };
          l2announcements = {
            enabled = lbIPAM;
            # failover within 3-7 seconds
            leaseDuration = "5s";
            leaseRenewDeadline = "2s";
            leaseRetryPeriod = "500ms";
          };
          # L2 leases renew every 2 s per Service: room for about 60.
          k8sClientRateLimit = {
            qps = 30;
            burst = 60;
          };
          bgpControlPlane.enabled = cluster.bgp != null;
          # Without address pools, Services get the nodes' addresses.
          nodeIPAM.enabled = !lbIPAM;
          defaultLBServiceIPAM =
            if lbIPAM
            then "lbipam"
            else "nodeipam";
          # L4 only: no Envoy per node.
          l7Proxy = false;
          envoy.enabled = false;
          operator.replicas = lib.min 2 (builtins.length nodes);
        }
        // lib.optionalAttrs (cluster.clusterId != null) {
          cluster = {
            inherit (cluster) name;
            id = cluster.clusterId;
          };
        };
    };
  }
