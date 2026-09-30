# Default-deny networking for workloads. Every namespace except the platform
# ones gets a NetworkPolicy "default-deny": its pods accept no connections and
# can only open DNS queries to CoreDNS. Allow what an app needs with its own
# NetworkPolicy; label a namespace `default-deny=off` to leave it open.
# See "Network policy" in README.md.
#
# Kubernetes has no cluster-wide NetworkPolicy, so every server watches the
# namespaces and applies the policy itself (idempotent, so several servers can
# do it at once). kube-router, embedded in k3s, enforces it.
{
  lib,
  pkgs,
  config,
  node,
  ...
}: let
  exempt = ["kube-system" "kube-public" "kube-node-lease" "longhorn-system" "metallb-system"];
  dns = [
    {
      protocol = "UDP";
      port = 53;
    }
    {
      protocol = "TCP";
      port = 53;
    }
  ];
  policy = (pkgs.formats.json {}).generate "default-deny.json" {
    apiVersion = "networking.k8s.io/v1";
    kind = "NetworkPolicy";
    metadata.name = "default-deny";
    spec = {
      podSelector = {};
      policyTypes = ["Ingress" "Egress"];
      egress = [
        {
          to = [
            {
              namespaceSelector.matchLabels."kubernetes.io/metadata.name" = "kube-system";
              podSelector.matchLabels."k8s-app" = "kube-dns";
            }
          ];
          ports = dns;
        }
      ];
    };
  };
in
  lib.mkIf (lib.elem "server" node.roles) {
    systemd.services.default-deny = {
      description = "Keep the default-deny NetworkPolicy in every namespace";
      after = ["k3s.service"];
      wantedBy = ["multi-user.target"];
      path = [config.services.k3s.package];
      # The watch ends when k3s restarts or the API server closes it; the
      # restart lists and re-applies everything.
      startLimitIntervalSec = 0;
      serviceConfig = {
        Restart = "always";
        RestartSec = 10;
      };
      script = ''
        k3s kubectl get namespaces --watch \
          -o 'jsonpath={.metadata.name} {.status.phase} {.metadata.labels.default-deny}{"\n"}' |
          while read -r ns phase setting; do
            case " ${toString exempt} " in *" $ns "*) continue ;; esac
            [[ $phase == Active ]] || continue
            if [[ $setting == off ]]; then
              k3s kubectl -n "$ns" delete networkpolicy default-deny --ignore-not-found || true
            else
              k3s kubectl -n "$ns" apply -f ${policy} || true
            fi
          done
      '';
    };
  }
