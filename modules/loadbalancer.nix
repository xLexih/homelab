# LoadBalancer addresses. With `loadBalancerIPs` set, MetalLB (layer 2) gives
# every service its own address from those pools; one node on the address's
# subnet answers ARP for it and another takes over when that node fails.
# Otherwise k3s ServiceLB publishes services on the node addresses.
{
  lib,
  cluster,
  node,
  ...
}: let
  ip = import ../lib/ip.nix lib;
  nodes = lib.attrValues cluster.nodes;
  name = builtins.replaceStrings ["." "/"] ["-" "-"];
  metadata = entry: {
    name = name entry;
    namespace = "metallb-system";
  };

  pool = entry: let
    announcers = lib.filter (n: n.address != null && ip.within n.address entry) nodes;
  in [
    {
      apiVersion = "metallb.io/v1beta1";
      kind = "IPAddressPool";
      metadata = metadata entry;
      # MetalLB wants a CIDR or a range
      spec.addresses = [
        (
          if lib.hasInfix "/" entry || lib.hasInfix "-" entry
          then entry
          else "${entry}/32"
        )
      ];
    }
    {
      apiVersion = "metallb.io/v1beta1";
      kind = "L2Advertisement";
      metadata = metadata entry;
      spec = {
        ipAddressPools = [(name entry)];
        interfaces = lib.unique (map (n: n.interface) announcers);
        nodeSelectors = [
          {
            matchExpressions = [
              {
                key = "kubernetes.io/hostname";
                operator = "In";
                values = map (n: n.name) announcers;
              }
            ];
          }
        ];
      };
    }
  ];
in
  lib.mkIf (cluster.loadBalancerIPs != [] && lib.elem "server" node.roles) {
    services.k3s = {
      disable = ["servicelb"];
      autoDeployCharts.metallb = {
        name = "metallb";
        repo = "https://metallb.github.io/metallb";
        version = "0.16.1";
        hash = "sha256-+wa7WE/LeFbxVzOypqKv9bYbXDUGh+NBwWOuJKWTitw=";
        targetNamespace = "metallb-system";
        createNamespace = true;
        extraFieldDefinitions.spec.failurePolicy = "abort";
        values = {
          # Layer 2 only: skip the bundled FRR (BGP) daemons.
          frrk8s.enabled = false;
          # The only controller assigns addresses to new services: leave a
          # failed node after 30 s instead of 300 s. Existing addresses stay
          # announced by the speakers meanwhile.
          controller.tolerations = map (key: {
            inherit key;
            operator = "Exists";
            effect = "NoExecute";
            tolerationSeconds = 30;
          }) ["node.kubernetes.io/not-ready" "node.kubernetes.io/unreachable"];
        };
      };
      # Separate file: these need the chart's CRDs and webhook, and k3s retries
      # a manifest until it applies.
      manifests.metallb-pools.content = lib.concatMap pool cluster.loadBalancerIPs;
    };
  }
