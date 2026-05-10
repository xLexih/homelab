{
  config,
  lib,
  self,
  clusterConfig,
  helpers,
  nodeName,
  nodeConfig,
  ...
}: let
  otherNodes = lib.filterAttrs (n: _: n != nodeName) clusterConfig.nodes;

  wgPrefixLength =
    lib.toInt
    (lib.last (lib.splitString "/" clusterConfig.network.wgCIDR));

  mkPeer = name: cfg: {
    publicKey = builtins.readFile "${self}/secrets/wireguard/${name}.pub";
    allowedIPs = [
      "${cfg.network.wgIP}/32" # exact host IP for mesh peering
      (helpers.nodePodCIDR name cfg)
    ];
    endpoint = helpers.getNodeEndpoint name cfg;
    persistentKeepalive = clusterConfig.network.wgKeepalive;
  };

  wgPort =
    if nodeConfig.network.wgPort != null
    then nodeConfig.network.wgPort
    else clusterConfig.network.wgPort;
in {
  age.secrets."wg-${nodeName}-key" = {
    file = "${self}/secrets/wireguard/${nodeName}.age";
    mode = "0400";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = ["${nodeConfig.network.wgIP}/${toString wgPrefixLength}"];
    listenPort = wgPort;
    # 1440 is standard for IPv4 on 1500-byte links (60 bytes WireGuard overhead).
    # Cilium further subtracts 50 bytes for Geneve encapsulation (wgMTU - 50).
    mtu = clusterConfig.network.wgMTU;
    table = "main"; # routes must be visible to k3s and Cilium
    privateKeyFile = config.age.secrets."wg-${nodeName}-key".path;
    peers = lib.mapAttrsToList mkPeer otherNodes;
  };

  systemd.services.k3s = {
    after = lib.mkDefault ["wireguard-wg0.service"];
    requires = lib.mkDefault ["wireguard-wg0.service"];
  };
}
