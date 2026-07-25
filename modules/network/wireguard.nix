{
  config,
  lib,
  pkgs,
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
    publicKey = builtins.readFile "${self}/secrets/hosts/${name}/wireguard.pub";
    allowedIPs = [
      "${cfg.network.wgIP}/32"
      (helpers.nodePodCIDR name cfg)
    ];
    endpoint = helpers.getNodeEndpoint nodeName name cfg;
    persistentKeepalive = clusterConfig.network.wgKeepalive;
  };

  podCIDRRoutes = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: cfg: "ip route replace ${helpers.nodePodCIDR name cfg} dev wg0"
    )
    otherNodes);

  masqRule = "iptables -t nat -C CILIUM_POST_nat -s ${nodeConfig.podCIDR} -o wg0 -j MASQUERADE 2>/dev/null || iptables -t nat -I CILIUM_POST_nat 1 -s ${nodeConfig.podCIDR} -o wg0 -j MASQUERADE";

  wgPort =
    if nodeConfig.network.wgPort != null
    then nodeConfig.network.wgPort
    else clusterConfig.network.wgPort;
in {
  age.secrets."wg-${nodeName}-key" = {
    file = "${self}/secrets/hosts/${nodeName}/wireguard.age";
    mode = "0400";
  };

  networking.wireguard.interfaces.wg0 = {
    ips = ["${nodeConfig.network.wgIP}/${toString wgPrefixLength}"];
    listenPort = wgPort;
    mtu = clusterConfig.network.wgMTU;
    table = "main";
    privateKeyFile = config.age.secrets."wg-${nodeName}-key".path;
    peers = lib.mapAttrsToList mkPeer otherNodes;
    postSetup = "${podCIDRRoutes}\n${masqRule}";
  };

  systemd.services.k3s = {
    after = lib.mkDefault ["wireguard-wg0.service"];
    requires = lib.mkDefault ["wireguard-wg0.service"];
  };

  systemd.services.ensure-masq-wg0 = let
    iptables = "${pkgs.iptables}/bin/iptables";
    rule = "-t nat -C CILIUM_POST_nat -s ${nodeConfig.podCIDR} -o wg0 -j MASQUERADE";
    add = "-t nat -I CILIUM_POST_nat 1 -s ${nodeConfig.podCIDR} -o wg0 -j MASQUERADE";
  in {
    description = "Ensure iptables MASQUERADE rule for pod traffic over wg0";
    after = ["network.target" "cilium.service"];
    wants = ["cilium.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${iptables} ${rule} || ${iptables} ${add}
    '';
  };

  systemd.timers.ensure-masq-wg0 = {
    description = "Periodically re-assert iptables MASQUERADE rule for pod traffic over wg0";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "5min";
    };
  };
}
