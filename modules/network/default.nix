{
  lib,
  clusterConfig,
  nodeConfig,
  ...
}: let
  iface = clusterConfig.network.lanInterface;
  useDHCP = nodeConfig.network.useDHCP or false;
in {
  imports = [
    ./wireguard.nix
    ./firewall.nix
    ./haproxy.nix
  ];

  networking.useDHCP = useDHCP;

  networking.interfaces.${iface} = lib.mkIf (!useDHCP) {
    ipv4.addresses = [
      {
        address = nodeConfig.network.lanIP;
        prefixLength = nodeConfig.network.lanPrefixLength;
      }
    ];
  };

  networking.defaultGateway = lib.mkIf (!useDHCP) nodeConfig.network.gateway;
  networking.nameservers = clusterConfig.network.nameservers;
}
