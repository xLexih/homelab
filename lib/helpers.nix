{
  lib,
  cluster,
}: rec {
  hasRole = role: node: builtins.elem role node.roles;

  nodesWithRole = role:
    lib.filterAttrs (_: node: hasRole role node) cluster.nodes;

  masterNodes = nodesWithRole "master";

  masterWgIPs = lib.mapAttrsToList (_: node: node.network.wgIP) masterNodes;

  initNode = let
    found =
      lib.findFirst
      (name: cluster.nodes.${name}.init)
      null
      (builtins.attrNames cluster.nodes);
  in
    if found == null
    then throw "No init node defined (this should have been caught by validation)"
    else found;

  getNodeEndpoint = nodeName: node: let
    port =
      if node.network.wgPort != null
      then node.network.wgPort
      else cluster.network.wgPort;
    host =
      if node.network.endpoint != null
      then node.network.endpoint
      else if cluster.network.domain != null
      then "${nodeName}.${cluster.network.domain}"
      else node.network.lanIP;
  in "${host}:${toString port}";

  # Returns the node's podCIDR or throws if not defined
  nodePodCIDR = nodeName: node:
    if node.podCIDR != null
    then node.podCIDR
    else throw "podCIDR must be defined for node ${nodeName}";

  validateCluster = let
    initNodes = lib.filterAttrs (_: n: n.init) cluster.nodes;
    initCount = builtins.length (builtins.attrNames initNodes);

    # Collect non‑null values from each node, then find duplicates
    findDups = mapper: let
      vals = lib.filter (v: v != null) (lib.mapAttrsToList (_: mapper) cluster.nodes);
    in
      if vals == []
      then []
      else
        lib.pipe vals [
          (lib.sort builtins.lessThan)
          (lib.groupBy (v: v))
          (lib.filterAttrs (_: v: builtins.length v > 1))
          builtins.attrNames
        ];

    # Nodes with missing podCIDR
    missingPodCIDR =
      lib.filterAttrs
      (_: node: node.podCIDR == null)
      cluster.nodes;

    dupPodCIDRs = findDups (n: n.podCIDR);
    dupWgIPs = findDups (n: n.network.wgIP);

    invalidPools =
      builtins.filter
      (loc: !builtins.hasAttr loc cluster.locations)
      (builtins.attrNames cluster.loadBalancer.pools);

    invalidNodeLocations =
      builtins.filter
      (loc: !builtins.hasAttr loc cluster.locations)
      (lib.mapAttrsToList (_: node: node.location) cluster.nodes);

    storageWithoutDataDisk =
      if cluster.storageBackend == "longhorn"
      then
        lib.filterAttrs
        (_: node:
          (hasRole "storage" node)
          && !(lib.any (d: lib.elem "data" d.roles) node.storage.disks))
        cluster.nodes
      else {};

    registryErrors =
      if cluster.registry.type == "docker" && cluster.storageBackend != "longhorn"
      then ["Docker registry requires storageBackend = 'longhorn'. Current: ${cluster.storageBackend}"]
      else [];

    dhcpMissingEndpoint =
      lib.filterAttrs
      (_: node:
        node.network.useDHCP
        && node.network.endpoint == null
        && cluster.network.domain == null)
      cluster.nodes;

    staticMissingIP =
      lib.filterAttrs
      (_: node:
        !node.network.useDHCP
        && (node.network.lanIP == null || node.network.gateway == null))
      cluster.nodes;

    errors =
      (
        if initCount == 0
        then ["No init node defined"]
        else if initCount > 1
        then ["Multiple init nodes: ${builtins.concatStringsSep ", " (builtins.attrNames initNodes)}"]
        else []
      )
      ++ (let
        initWithoutMaster = lib.filterAttrs (_: n: n.init && !(builtins.elem "master" n.roles)) cluster.nodes;
      in
        if initWithoutMaster != {}
        then ["Init node(s) must have 'master' role: ${builtins.concatStringsSep ", " (builtins.attrNames initWithoutMaster)}"]
        else [])
      ++ (
        if missingPodCIDR != {}
        then ["Nodes missing podCIDR: ${builtins.concatStringsSep ", " (builtins.attrNames missingPodCIDR)}"]
        else []
      )
      ++ (
        if dupPodCIDRs != []
        then ["Duplicate podCIDRs: ${builtins.concatStringsSep ", " dupPodCIDRs}"]
        else []
      )
      ++ (
        if dupWgIPs != []
        then ["Duplicate WireGuard IPs: ${builtins.concatStringsSep ", " dupWgIPs}"]
        else []
      )
      ++ (
        if invalidPools != []
        then ["Invalid LoadBalancer pools (location missing): ${builtins.concatStringsSep ", " invalidPools}"]
        else []
      )
      ++ (
        if invalidNodeLocations != []
        then ["Node locations reference undefined locations: ${builtins.concatStringsSep ", " invalidNodeLocations}"]
        else []
      )
      ++ (
        if storageWithoutDataDisk != {}
        then ["Storage nodes without data disk: ${builtins.concatStringsSep ", " (builtins.attrNames storageWithoutDataDisk)}"]
        else []
      )
      ++ registryErrors
      ++ (
        if dhcpMissingEndpoint != {}
        then ["Nodes using DHCP without endpoint or domain: ${builtins.concatStringsSep ", " (builtins.attrNames dhcpMissingEndpoint)}"]
        else []
      )
      ++ (
        if staticMissingIP != {}
        then ["Nodes with static IP missing lanIP or gateway: ${builtins.concatStringsSep ", " (builtins.attrNames staticMissingIP)}"]
        else []
      );
  in {
    inherit errors;
    valid = errors == [];
  };
}
