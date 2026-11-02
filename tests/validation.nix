# Each case breaks one rule of a valid cluster (tests/cluster.nix without BGP)
# and must be rejected with the message its name is a substring of.
# Run alone with: nix build .#checks.x86_64-linux.validation
{
  lib,
  pkgs,
  clusterLib,
}: let
  base = removeAttrs (import ./cluster.nix) ["bgp"];
  set = lib.recursiveUpdate base;
  bgp = peer: {
    asn = 65100;
    peers = [
      {
        address = peer;
        asn = 65000;
      }
    ];
  };

  cases = {
    "odd number of servers" = base // {nodes = removeAttrs base.nodes ["s3"];};
    "`init` must name" = removeAttrs base ["init"];
    "inside network.wgCIDR" = set {nodes.s2.wgIP = "10.200.0.2";};
    "must be unique" = set {nodes.s2.wgIP = "10.100.0.1";};
    "must not overlap" = set {network.serviceCIDR = "10.42.128.0/17";};
    "need `dataDisk`" = set {nodes.s2.roles = ["server" "storage"];};
    "inside the `address` subnet" = base // {loadBalancerIPs = ["10.9.9.9"];};
    "entries must not overlap" = base // {loadBalancerIPs = ["10.0.0.200-10.0.0.210" "10.0.0.210/32"];};
    "include node or gateway" = base // {loadBalancerIPs = ["10.0.0.1-10.0.0.10"];};
    "written low-high" = base // {loadBalancerIPs = ["10.0.0.210-10.0.0.200"];};
    "no WireGuard path" = set {nodes.s3.location = "elsewhere";};
    "share one `location`" = set {
      nodes.s3 = {
        location = "elsewhere";
        endpoint = "s3.example.org";
      };
    };
    "set some" =
      base
      // {
        loadBalancerIPs = [];
        bgp = bgp "10.0.0.250";
      };
    "every bgp peer" = base // {bgp = bgp "10.9.9.9";};
  };

  errors = definition: clusterLib.validate (clusterLib.evalCluster "test" definition);
  rejected = expected: definition:
    lib.any (lib.hasInfix expected) (errors definition)
    || throw "validation should report '${expected}', got: ${builtins.toJSON (errors definition)}";
in
  assert errors base == [] || throw "the base cluster should be valid, got: ${builtins.toJSON (errors base)}";
  assert lib.all (x: x) (lib.mapAttrsToList rejected cases);
    pkgs.runCommand "validation" {} "touch $out"
