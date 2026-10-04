{
  inputs,
  lib,
  pkgs,
}: rec {
  ip = import ./ip.nix lib;

  evalCluster = name: definition:
    (lib.evalModules {
      modules = [./options.nix definition {config.name = name;}];
    }).config;

  # Cross-field rules the option types cannot express. Returns error messages.
  validate = c: let
    nodes = lib.attrValues c.nodes;
    has = role: n: lib.elem role n.roles;
    servers = lib.filter (has "server") nodes;
    wgIPs = map (n: n.wgIP) nodes;
    require = ok: msg: lib.optional (!ok) msg;
    net = c.network;
    lbs = c.loadBalancerIPs;
    reserved = lib.filter (a: a != null) (lib.concatMap (n: [n.ip n.gateway]) nodes);
    pairs = xs: lib.concatLists (lib.imap0 (i: a: map (b: [a b]) (lib.drop (i + 1) xs)) xs);
    lbClash = lib.any (p: ip.overlaps (lib.head p) (lib.last p)) (pairs lbs);
    # b can open a WireGuard session to a (mirrors `endpoint` in modules/network.nix)
    dialable = a: b: a.endpoint != null || a.location == b.location && a.ip != null;
    isolated = lib.filter (p: !(dialable (lib.head p) (lib.last p) || dialable (lib.last p) (lib.head p))) (pairs nodes);

    nodeErrors = n: let
      require' = ok: msg: require ok "node ${n.name}: ${msg}";
    in
      lib.concatLists [
        (require' (builtins.match "[a-z0-9]([-a-z0-9]*[a-z0-9])?" n.name != null) "name must be a lowercase DNS label")
        (require' (ip.within net.wgCIDR n.wgIP) "wgIP must be inside network.wgCIDR (${net.wgCIDR})")
        (require' (n.sshHost != null) "set `address` or `endpoint` so it can be reached")
        (require' (n.address == null || n.gateway != null) "a static `address` needs a `gateway`")
        (require' (n.platform == "lxc" || n.disk != null) "VM nodes need `disk`")
        (require' (n.platform == "lxc" || !(has "storage" n) || n.dataDisk != null) "VM storage nodes need `dataDisk`")
        (require' (n.platform == "vm" || n.disk == null && n.dataDisk == null) "LXC disks are managed by the host; remove `disk`/`dataDisk`")
        (require' (n.platform == "vm" || !(has "gpu" n)) "the gpu role is only supported on VMs")
      ];
  in
    lib.concatLists (
      [
        (require (servers != []) "at least one node needs the \"server\" role")
        (require (servers == [] || lib.mod (builtins.length servers) 2 == 1) "use an odd number of servers so etcd keeps quorum (found ${toString (builtins.length servers)})")
        (require (servers == [] || lib.any (n: n.name == c.init) servers) "`init` must name the server that bootstrapped etcd")
        (require (lib.unique wgIPs == wgIPs) "wgIP values must be unique")
        (require (!(ip.overlaps net.podCIDR net.serviceCIDR || ip.overlaps net.podCIDR net.wgCIDR || ip.overlaps net.serviceCIDR net.wgCIDR)) "network.podCIDR, serviceCIDR and wgCIDR must not overlap")
        (require (lib.all (e: (ip.span e).first <= (ip.span e).last) lbs) "loadBalancerIPs ranges must be written low-high")
        (require (c.bgp != null || lib.all (e: ip.lanNodes nodes e != []) lbs) "every loadBalancerIPs entry must be inside the `address` subnet of at least one node (or set `bgp`)")
        (require (lib.all (e: builtins.length (lib.unique (map (n: n.location) (ip.lanNodes nodes e))) <= 1) lbs) "the nodes on the subnet of a loadBalancerIPs entry must share one `location`")
        (require (!lbClash) "loadBalancerIPs entries must not overlap")
        (require (c.bgp == null || lbs != []) "`bgp` advertises loadBalancerIPs; set some")
        (require (c.bgp == null || lib.all (p: ip.lanNodes nodes p.address != []) c.bgp.peers) "every bgp peer must be inside the `address` subnet of some nodes, which peer with it")
        (require (isolated == []) "no WireGuard path between ${lib.concatMapStringsSep ", " (p: "${(lib.head p).name} and ${(lib.last p).name}") isolated}; give one of each pair an `endpoint`")
        (require (!lib.any (a: lib.any (e: ip.within e a) lbs) reserved) "loadBalancerIPs must not include node or gateway addresses")
      ]
      ++ map nodeErrors nodes
    );

  # Modules of one node; shared by the real systems and the VM test.
  nodeModules = cluster: secrets: node: [
    ../modules
    (
      if node.platform == "lxc"
      then ../modules/lxc.nix
      else ../modules/vm.nix
    )
    {_module.args = {inherit cluster node secrets;};}
  ];

  checked = name: definition: let
    evaluated = evalCluster name definition;
    errors = validate evaluated;
  in
    if errors == []
    then evaluated
    else throw "cluster ${name}:\n  - ${lib.concatStringsSep "\n  - " errors}";

  mkCluster = name: dir: let
    cluster = checked name {
      _file = dir + "/cluster.nix";
      config = import (dir + "/cluster.nix");
    };
    secrets = dir + "/secrets";
  in {
    nixosConfigurations = lib.mapAttrs' (nodeName: node:
      lib.nameValuePair "${name}-${nodeName}" (lib.nixosSystem {
        specialArgs = {inherit inputs;};
        modules = nodeModules cluster secrets node ++ [{nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;}];
      }))
    cluster.nodes;

    cli = pkgs.callPackage ./cli.nix {
      inherit cluster secrets;
      secretsDir = "clusters/${name}/secrets";
    };
  };
}
