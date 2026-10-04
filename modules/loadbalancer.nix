# LoadBalancer addresses (Cilium LB IPAM). Entries inside a LAN subnet are
# announced over ARP by one of the nodes on that subnet (L2 announcements)
# and moved to another when it fails; validation keeps those nodes in one
# location. With nodes in several such locations, a Service picks its
# location with the label topology.kubernetes.io/zone=<location>. `bgp`
# additionally advertises every address to the routers.
{
  lib,
  cluster,
  node,
  ...
}: let
  ip = import ../lib/ip.nix lib;
  nodes = lib.attrValues cluster.nodes;
  lbs = cluster.loadBalancerIPs;
  zoneLabel = "topology.kubernetes.io/zone";
  hostnames = ns: {
    matchExpressions = [
      {
        key = "kubernetes.io/hostname";
        operator = "In";
        values = map (n: n.name) ns;
      }
    ];
  };

  # location -> entries announced there; "" for entries only BGP can reach
  locationOf = e: let
    ns = ip.lanNodes nodes e;
  in
    if ns == []
    then ""
    else (builtins.head ns).location;
  groups = lib.groupBy locationOf lbs;
  locations = lib.filter (l: l != "") (lib.attrNames groups);
  # With one location every Service may take any address.
  selector = l: lib.optionalAttrs (builtins.length locations > 1 && l != "") {serviceSelector.matchLabels.${zoneLabel} = l;};

  pool = l: entries: {
    apiVersion = "cilium.io/v2";
    kind = "CiliumLoadBalancerIPPool";
    metadata.name =
      if l == ""
      then "routed"
      else l;
    spec =
      {
        blocks = map (e: let
          ends = lib.splitString "-" e;
        in
          if builtins.length ends == 2
          then {
            start = builtins.head ends;
            stop = lib.last ends;
          }
          else {cidr = (ip.parse e).ip + "/${toString (ip.parse e).prefix}";})
        entries;
      }
      // selector l;
  };

  l2Policy = l: let
    announcers = lib.unique (lib.concatMap (ip.lanNodes nodes) groups.${l});
  in {
    apiVersion = "cilium.io/v2alpha1";
    kind = "CiliumL2AnnouncementPolicy";
    metadata.name = l;
    spec =
      {
        nodeSelector = hostnames announcers;
        interfaces = map (i: "^${i}$") (lib.unique (map (n: n.interface) announcers));
        loadBalancerIPs = true;
      }
      // selector l;
  };

  # Each router peers with the nodes on its subnet; one config per subnet,
  # since a node may match only one.
  routerGroups = lib.attrValues (lib.groupBy (p: lib.concatMapStringsSep "," (n: n.name) (ip.lanNodes nodes p.address)) cluster.bgp.peers);
  bgp = lib.optionals (cluster.bgp != null) (
    (lib.imap0 (i: peers: {
        apiVersion = "cilium.io/v2";
        kind = "CiliumBGPClusterConfig";
        metadata.name = "routers-${toString i}";
        spec = {
          nodeSelector = hostnames (ip.lanNodes nodes (builtins.head peers).address);
          bgpInstances = [
            {
              name = "cluster";
              localASN = cluster.bgp.asn;
              peers =
                map (p: {
                  name = "router-${builtins.replaceStrings ["."] ["-"] p.address}";
                  peerASN = p.asn;
                  peerAddress = p.address;
                  peerConfigRef.name = "router";
                })
                peers;
            }
          ];
        };
      })
      routerGroups)
    ++ [
      {
        apiVersion = "cilium.io/v2";
        kind = "CiliumBGPPeerConfig";
        metadata.name = "router";
        spec.families = [
          {
            afi = "ipv4";
            safi = "unicast";
            advertisements.matchLabels.advertise = "loadbalancer";
          }
        ];
      }
      {
        apiVersion = "cilium.io/v2";
        kind = "CiliumBGPAdvertisement";
        metadata = {
          name = "loadbalancer";
          labels.advertise = "loadbalancer";
        };
        spec.advertisements = [
          {
            advertisementType = "Service";
            service.addresses = ["LoadBalancerIP"];
            # every Service except those labelled bgp=off
            selector.matchExpressions = [
              {
                key = "bgp";
                operator = "NotIn";
                values = ["off"];
              }
            ];
          }
        ];
      }
    ]
  );
in
  lib.mkIf (lbs != [] && lib.elem "server" node.roles) {
    # Separate from the chart: these need Cilium's CRDs, and k3s retries a
    # manifest until it applies.
    services.k3s.manifests.loadbalancer.content =
      lib.mapAttrsToList pool groups
      ++ map l2Policy locations
      ++ bgp;
  }
