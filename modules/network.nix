# LAN address, WireGuard full mesh and firewall.
#
# Everything Kubernetes does (API, etcd, kubelet, Cilium's Geneve tunnels)
# travels over wg0; the LAN only exposes SSH and WireGuard. Cilium handles
# LoadBalancer traffic in eBPF before it reaches the input firewall.
{
  lib,
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
      # SSH is opened by services.openssh.
      allowedUDPPorts = [net.wgPort];
      # wg0, Cilium's host and tunnel devices, and the pods' veths
      trustedInterfaces = ["wg0" "cilium_host" "cilium_net" "cilium_geneve" "lxc+"];
      checkReversePath = "loose";
    };

    wireguard.interfaces.wg0 = {
      ips = ["${node.wgIP}/${toString (ip.parse net.wgCIDR).prefix}"];
      listenPort = net.wgPort;
      mtu = net.wgMTU;
      privateKeyFile = config.age.secrets.wireguard.path;
      peers =
        map (peer: let
          e = endpoint peer;
        in {
          inherit (peer) name;
          publicKey = publicKey peer.name;
          allowedIPs = ["${peer.wgIP}/32"];
          endpoint = e;
          persistentKeepalive = 25;
          # A DNS name is resolved once; re-resolve it so an address change heals.
          dynamicEndpointRefreshSeconds = lib.mkIf (e != null && builtins.match "[0-9.]+:[0-9]+" e == null) 300;
        })
        peers;
    };
  };
}
