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
      "${cfg.network.wgIP}/32"
      (helpers.nodePodCIDR name cfg)
    ];
    endpoint = helpers.getNodeEndpoint name cfg;
    persistentKeepalive = clusterConfig.network.wgKeepalive;
  };

  podCIDRRoutes = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: cfg:
    "ip route replace ${helpers.nodePodCIDR name cfg} dev wg0"
  ) otherNodes);

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
    mtu = clusterConfig.network.wgMTU;
    table = "main";
    privateKeyFile = config.age.secrets."wg-${nodeName}-key".path;
    peers = lib.mapAttrsToList mkPeer otherNodes;
    postSetup = podCIDRRoutes;
  };

  systemd.services.k3s = {
    after = lib.mkDefault ["wireguard-wg0.service"];
    requires = lib.mkDefault ["wireguard-wg0.service"];
  };
}
