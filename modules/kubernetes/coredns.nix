{
  lib,
  clusterConfig,
  helpers,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) kubectl log;

  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;
  replicas = clusterConfig.coredns.replicas;
in
  lib.mkIf (isInit && isMaster) {
    systemd.services.patch-coredns = {
      wantedBy = ["multi-user.target"];
      after = ["k3s.service" "helm-deploy-cilium.service"];
      requires = ["k3s.service"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5m";
      };

      script = ''
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        ${log}

        log coredns "Patching deployment..."

        until ${kubectl} get deployment coredns -n kube-system &>/dev/null; do
          sleep 5
        done

        # Scale to the desired number of replicas
        ${kubectl} scale deployment coredns -n kube-system --replicas=${toString replicas}

        # Spread replicas across nodes to survive single-node failures
        ${kubectl} patch deployment coredns -n kube-system --type='merge' -p '{
          "spec": {
            "template": {
              "spec": {
                "affinity": {
                  "podAntiAffinity": {
                    "preferredDuringSchedulingIgnoredDuringExecution": [
                      {
                        "weight": 100,
                        "podAffinityTerm": {
                          "labelSelector": { "matchLabels": { "k8s-app": "kube-dns" } },
                          "topologyKey": "kubernetes.io/hostname"
                        }
                      }
                    ]
                  }
                }
              }
            }
          }
        }'

        ${kubectl} rollout status deployment/coredns -n kube-system --timeout=120s

        # PDB: keep at least one CoreDNS pod alive during voluntary disruptions
        ${lib.optionalString (replicas > 1) ''
          cat <<EOF | ${kubectl} apply -f -
          apiVersion: policy/v1
          kind: PodDisruptionBudget
          metadata:
            name: coredns
            namespace: kube-system
          spec:
            minAvailable: 1
            selector:
              matchLabels:
                k8s-app: kube-dns
          EOF
        ''}

        log coredns "Done"
      '';
    };
  }
