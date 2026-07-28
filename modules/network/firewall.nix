{
  clusterConfig,
  helpers,
  lib,
  nodeName,
  nodeConfig,
  ...
}: let
  inherit (helpers) nodeWgPort;

  wgPort = nodeWgPort nodeName;

  sshPort =
    if nodeConfig.network.sshPort != null
    then nodeConfig.network.sshPort
    else 22;

  exposeIngress = clusterConfig.loadBalancer.enable;
in {
  networking.firewall = {
    enable = true;
    trustedInterfaces = [
      "wg0"
      "cilium_net"
      "cilium_host"
      "cilium_geneve"
      "lxc+"
    ];

    interfaces.${clusterConfig.network.lanInterface} = {
      allowedTCPPorts = [sshPort] ++ lib.optionals exposeIngress [80 443];
      allowedUDPPorts = [wgPort];
    };

    checkReversePath = "loose"; # allow asymmetric routing for kube-vip VIP
    allowPing = true;
  };

  # Disable reverse path filtering on the WireGuard interface for kube-vip
  boot.kernel.sysctl = {
    "net.ipv4.conf.wg0.rp_filter" = 0;
  };
}
