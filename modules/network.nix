# LAN address, WireGuard full mesh, firewall and the optional virtual IP.
#
# Everything Kubernetes does (API, etcd, kubelet, flannel VXLAN) travels over
# wg0; the LAN only exposes SSH, WireGuard and VRRP. LoadBalancer services
# (k3s ServiceLB) are DNATed before the input firewall, as are hostPorts.
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
  nodes = lib.attrValues cluster.nodes;
  peers = lib.filter (n: n.name != node.name) nodes;
  port = toString net.wgPort;

  endpoint = peer:
    if peer.location == node.location && peer.ip != null
    then "${peer.ip}:${port}"
    else if peer.endpoint != null
    then "${peer.endpoint}:${port}"
    else null; # the peer dials us

  publicKey = name: let
    file = secrets + "/hosts/${name}/wireguard.pub";
  in
    if builtins.pathExists file
    then lib.removeSuffix "\n" (builtins.readFile file)
    else throw "missing ${file}; run: nix run .#${cluster.name} -- secrets sync";

  # Nodes on the VIP's subnet share it through VRRP.
  vipNodes = lib.filter (n: n.address != null && ip.contains n.address cluster.vip) nodes;
  holdsVip = cluster.vip != null && lib.any (n: n.name == node.name) vipNodes;
in {
  age.secrets.wireguard.file = secrets + "/hosts/${node.name}/wireguard.age";

  networking = {
    hostName = node.name;
    useDHCP = node.address == null;
    interfaces = lib.optionalAttrs (node.address != null) {
      ${node.interface}.ipv4.addresses = [
        {
          address = node.ip;
          prefixLength = (ip.parse node.address).prefix;
        }
      ];
    };
    defaultGateway = node.gateway;
    nameservers = lib.mkIf (node.address != null) net.nameservers;

    firewall = {
      # SSH is opened by services.openssh, VRRP by keepalived.
      allowedUDPPorts = [net.wgPort];
      trustedInterfaces = ["wg0" "cni0" "flannel.1"];
      checkReversePath = "loose";
    };

    wireguard.interfaces.wg0 = {
      ips = ["${node.wgIP}/${toString (ip.parse net.wgCIDR).prefix}"];
      listenPort = net.wgPort;
      privateKeyFile = config.age.secrets.wireguard.path;
      peers =
        map (peer: {
          inherit (peer) name;
          publicKey = publicKey peer.name;
          allowedIPs = ["${peer.wgIP}/32"];
          endpoint = endpoint peer;
          persistentKeepalive = 25;
        })
        peers;
    };
  };

  services.keepalived = lib.mkIf holdsVip {
    enable = true;
    openFirewall = true;
    vrrpScripts.k3s = {
      script = "${pkgs.systemd}/bin/systemctl is-active --quiet k3s.service";
      interval = 2;
      rise = 2;
      fall = 2;
      user = "nobody";
    };
    vrrpInstances.vip = {
      inherit (node) interface;
      # Unique per VIP, so several clusters can share a LAN.
      virtualRouterId = lib.toInt (lib.last (lib.splitString "." cluster.vip));
      unicastSrcIp = node.ip;
      unicastPeers = map (n: n.ip) (lib.filter (n: n.name != node.name) vipNodes);
      virtualIps = [{addr = "${cluster.vip}/${toString (ip.parse node.address).prefix}";}];
      trackScripts = ["k3s"];
    };
  };
}
