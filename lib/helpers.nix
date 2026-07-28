{
  lib,
  cluster,
}: rec {
  # --- SSH helpers (used by all scripts) ---

  nodeIp = n: let
    net = cluster.nodes.${n}.network;
  in
    if net.endpoint != null
    then net.endpoint
    else net.lanIP;

  nodePort = n: let
    net = cluster.nodes.${n}.network;
  in
    if net.sshPort != null
    then toString net.sshPort
    else "22";

  nodeUser = n: let
    net = cluster.nodes.${n}.network;
  in
    if net.sshUser != null
    then net.sshUser
    else "admin";

  nodeWgIP = n: cluster.nodes.${n}.network.wgIP;

  nodeWgPort = n: let
    net = cluster.nodes.${n}.network;
  in
    if net.wgPort != null
    then net.wgPort
    else cluster.network.wgPort;

  sshOpts = "-o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=no -o ControlPath=none";

  mkKnownHosts = secretsRoot:
    lib.concatMapStrings (name: let
      net = cluster.nodes.${name}.network;
      port = nodePort name;
      key = lib.removeSuffix "\n" (builtins.readFile (secretsRoot + "/hosts/${name}/ssh-key.pub"));
      hosts = lib.unique (lib.filter (host: host != null) [
        (nodeIp name)
        net.lanIP
        net.wgIP
        net.endpoint
        net.wgEndpoint
      ]);
      knownHost = host:
        if port == "22"
        then host
        else "[${host}]:${port}";
    in
      lib.concatMapStrings (host: "${knownHost host} ${key}\n") hosts)
    (builtins.attrNames cluster.nodes);

  mkResolver = name: func: let
    nodeNames = builtins.attrNames cluster.nodes;
    cases = lib.concatMapStringsSep "\n        " (n: "${n}) echo '${func n}' ;;") nodeNames;
  in ''
    resolve_${name}() {
      case "$1" in
        ${cases}
        *) echo "Unknown node: $1" >&2; exit 1 ;;
      esac
    }
  '';

  # --- Cluster helpers ---

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

  getNodeEndpoint = sourceName: nodeName: node: let
    sameLocation = cluster.nodes.${sourceName}.location == node.location;
    listenPort =
      if node.network.wgPort != null
      then node.network.wgPort
      else cluster.network.wgPort;
    port =
      if !sameLocation && node.network.endpointPort != null
      then node.network.endpointPort
      else listenPort;
    host =
      if sameLocation && node.network.lanIP != null
      then node.network.lanIP
      else if node.network.wgEndpoint != null
      then node.network.wgEndpoint
      else if node.network.endpoint != null
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

    # Collect non-null values from each node, then find duplicates.
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
          && node.platform == "vm"
          && !(lib.any (d: lib.elem "data" d.roles) node.storage.disks))
        cluster.nodes
      else {};

    registryErrors =
      if cluster.registry.type != "docker"
      then []
      else if cluster.storageBackend == "longhorn"
      then []
      else if cluster.storageBackend == "local" && builtins.length (builtins.attrNames cluster.nodes) == 1
      then []
      else ["Docker registry requires storageBackend = 'longhorn' (or 'local' with a single node). Current: ${cluster.storageBackend}"];

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

    lxcNodesWithDisks =
      lib.filterAttrs
      (_: node:
        node.platform
        == "lxc"
        && node.storage.disks != [])
      cluster.nodes;

    masterCount = builtins.length (builtins.attrNames masterNodes);

    corednsReplicas = cluster.coredns.replicas or 2;

    # Convert dotted IPv4 to numeric form for exact CIDR comparisons.
    ipToNum = ip: let
      o = lib.splitString "." ip;
    in
      lib.foldl' (acc: x: acc * 256 + lib.toInt x) 0 o;

    pow2 = exponent:
      if exponent == 0
      then 1
      else 2 * pow2 (exponent - 1);

    cidrBounds = value: let
      parts = lib.splitString "/" value;
      ip = builtins.head parts;
      prefix =
        if builtins.length parts == 1
        then 32
        else lib.toInt (lib.last parts);
      size = pow2 (32 - prefix);
      first = (ipToNum ip / size) * size;
    in {
      inherit first;
      last = first + size - 1;
    };

    cidrContainedIn = child: parent: let
      childBounds = cidrBounds child;
      parentBounds = cidrBounds parent;
    in
      childBounds.first
      >= parentBounds.first
      && childBounds.last <= parentBounds.last;

    cidrOverlaps = left: right: let
      leftBounds = cidrBounds left;
      rightBounds = cidrBounds right;
    in
      leftBounds.first
      <= rightBounds.last
      && rightBounds.first <= leftBounds.last;

    overlappingPairs = entries:
      lib.concatLists (lib.imap0 (index: left:
        map
        (right: "${left.name} (${left.cidr}) overlaps ${right.name} (${right.cidr})")
        (lib.filter (right: cidrOverlaps left.cidr right.cidr) (lib.drop (index + 1) entries)))
      entries);

    nodePodCIDRs = lib.filter (entry: entry.cidr != null) (
      lib.mapAttrsToList (name: node: {
        inherit name;
        cidr = node.podCIDR;
      })
      cluster.nodes
    );

    overlappingPodCIDRs = overlappingPairs nodePodCIDRs;

    overlappingClusterCIDRs = overlappingPairs [
      {
        name = "network.podCIDR";
        cidr = cluster.network.podCIDR;
      }
      {
        name = "network.serviceCIDR";
        cidr = cluster.network.serviceCIDR;
      }
      {
        name = "network.wgCIDR";
        cidr = cluster.network.wgCIDR;
      }
    ];

    podCIDROutOfRange =
      lib.filterAttrs (
        name: node:
          node.podCIDR
          != null
          && !cidrContainedIn node.podCIDR cluster.network.podCIDR
      )
      cluster.nodes;

    wgIPOutOfRange =
      lib.filterAttrs (
        _: node:
          !cidrContainedIn node.network.wgIP cluster.network.wgCIDR
      )
      cluster.nodes;

    invalidPoolOrder = lib.filterAttrs (
      _: pool:
        ipToNum pool.start > ipToNum pool.stop
    ) (cluster.loadBalancer.pools or {});

    poolOutsideLocation = lib.filterAttrs (
      location: pool: let
        staticNodes =
          lib.filterAttrs (
            _: node:
              node.location
              == location
              && node.network.lanIP != null
          )
          cluster.nodes;
        inLocationSubnet = lib.any (node: let
          lanCIDR = "${node.network.lanIP}/${toString node.network.lanPrefixLength}";
        in
          cidrContainedIn pool.start lanCIDR
          && cidrContainedIn pool.stop lanCIDR)
        (lib.attrValues staticNodes);
      in
        staticNodes != {} && !inLocationSubnet
    ) (cluster.loadBalancer.pools or {});

    invalidName = let
      nameOk = builtins.match "^[a-zA-Z][-a-zA-Z0-9]*$" cluster.name;
    in
      nameOk == null;

    storageNodeCount = builtins.length (builtins.attrNames (nodesWithRole "storage"));

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
        if overlappingPodCIDRs != []
        then ["Overlapping node podCIDRs: ${builtins.concatStringsSep "; " overlappingPodCIDRs}"]
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
      )
      ++ (
        if lxcNodesWithDisks != {}
        then ["LXC nodes use host-managed storage and must leave storage.disks empty: ${builtins.concatStringsSep ", " (builtins.attrNames lxcNodesWithDisks)}"]
        else []
      )
      ++ (
        if masterCount > 0 && corednsReplicas > masterCount
        then ["coredns.replicas (${toString corednsReplicas}) exceeds master node count (${toString masterCount}). Set coredns.replicas <= ${toString masterCount}."]
        else []
      )
      ++ (
        if masterCount > 1 && lib.mod masterCount 2 == 0
        then ["HA clusters require an odd number of master nodes; found ${toString masterCount}"]
        else []
      )
      ++ (
        if cluster.storageBackend == "longhorn" && storageNodeCount < 2
        then ["Longhorn requires at least two storage nodes; found ${toString storageNodeCount}"]
        else []
      )
      ++ (
        if overlappingClusterCIDRs != []
        then ["Cluster network CIDRs overlap: ${builtins.concatStringsSep "; " overlappingClusterCIDRs}"]
        else []
      )
      ++ (
        if podCIDROutOfRange != {}
        then ["Node podCIDR not within cluster.network.podCIDR (${cluster.network.podCIDR}): ${builtins.concatStringsSep ", " (builtins.attrNames podCIDROutOfRange)}"]
        else []
      )
      ++ (
        if wgIPOutOfRange != {}
        then ["Node wgIP not within cluster.network.wgCIDR (${cluster.network.wgCIDR}): ${builtins.concatStringsSep ", " (builtins.attrNames wgIPOutOfRange)}"]
        else []
      )
      ++ (
        if invalidPoolOrder != {}
        then ["LoadBalancer pool start > stop: ${builtins.concatStringsSep ", " (lib.mapAttrsToList (loc: pool: "${loc}: ${pool.start} > ${pool.stop}") invalidPoolOrder)}"]
        else []
      )
      ++ (
        if poolOutsideLocation != {}
        then ["LoadBalancer pools outside their location LAN subnet: ${builtins.concatStringsSep ", " (builtins.attrNames poolOutsideLocation)}"]
        else []
      )
      ++ (
        if invalidName
        then ["Cluster name '${cluster.name}' is not a valid identifier. Use alphanumeric characters and hyphens, starting with a letter."]
        else []
      );
  in {
    inherit errors;
    valid = errors == [];
  };
}
