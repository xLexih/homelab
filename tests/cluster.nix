# The cluster the VM test (tests/default.nix) boots: three servers, one agent.
# Addresses live on the test network's eth1, next to the ones the test
# framework assigns there. The deployer VM (10.0.0.250) doubles as the BGP
# router.
{
  stateVersion = "26.05";
  k3sVersion = "1.35";
  init = "s1";
  clusterId = 1;
  loadBalancerIPs = ["10.0.0.200"];
  bgp = {
    asn = 65100;
    peers = [
      {
        address = "10.0.0.250";
        asn = 65000;
      }
    ];
  };
  # small VMs
  reserved = {
    server = "cpu=100m,memory=256Mi";
    agent = "cpu=100m,memory=128Mi";
  };

  nodes = let
    node = n: roles: {
      inherit roles;
      wgIP = "10.100.0.${toString n}";
      address = "10.0.0.${toString n}/24";
      gateway = "10.0.0.254";
      interface = "eth1";
      disk = "/dev/vda";
    };
  in {
    s1 = node 1 ["server"];
    s2 = node 2 ["server"];
    s3 = node 3 ["server"];
    a1 = node 4 [];
  };
}
