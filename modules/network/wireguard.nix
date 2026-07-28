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

  ip = "${pkgs.iproute2}/bin/ip";

  podCIDRRoutes = lib.concatStringsSep "\n" (lib.mapAttrsToList (
      name: cfg: "${ip} route replace ${helpers.nodePodCIDR name cfg} dev wg0"
    )
    otherNodes);

  inherit (helpers) nodeWgPort;

  wgPort = nodeWgPort nodeName;
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
    postSetup = "${podCIDRRoutes}";
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
    after = ["network.target" "k3s.service"];
    wants = ["k3s.service"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for attempt in $(seq 1 60); do
        if ${iptables} -t nat -S CILIUM_POST_nat >/dev/null 2>&1; then
          ${iptables} ${rule} || ${iptables} ${add}
          exit 0
        fi
        sleep 5
      done
      echo "CILIUM_POST_nat was not created within 5 minutes" >&2
      exit 1
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
