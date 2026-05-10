{
  clusterConfig,
  nodeConfig,
  ...
}: let
  wgPort =
    if nodeConfig.network.wgPort != null
    then nodeConfig.network.wgPort
    else clusterConfig.network.wgPort;

  sshPort =
    if nodeConfig.network.sshPort != null
    then nodeConfig.network.sshPort
    else 22;

  apiPort = clusterConfig.network.apiServerPort;
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
      allowedTCPPorts = [
        sshPort
        80 # HTTP ingress (APISix)
        443 # HTTPS ingress (APISix)
        2222 # alternative SSH
        apiPort
      ];
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
