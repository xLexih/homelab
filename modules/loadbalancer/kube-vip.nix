{
  lib,
  clusterConfig,
  helmDefaults,
  nodeConfig,
  ...
}: let
  inherit (helmDefaults) versions mkHelmService kubectl log;

  isInit = nodeConfig.init;
  lb = clusterConfig.loadBalancer;

  kubeVipArgs = [
    "--set env.vip_arp=true"
    "--set env.vip_subnet=32"
    "--set env.svc_enable=true"
    "--set env.svc_election=true" # Per-service leader election for better load distribution
    "--set env.lb_enable=true"
    "--set env.vip_interface=${clusterConfig.network.lanInterface}"
    "--set env.vip_leaderelection=true"
    # Lease timing: 5min lease, 2min renew deadline, 30s retry
    "--set env.vip_leaseduration=300"
    "--set env.vip_renewdeadline=120"
    "--set env.vip_retryperiod=30"
    # Preserve VIP during leadership transition (smoother failover)
    "--set env.preserveVIPOnLeadershipLoss=true"
    "--set-json nodeSelector='{\"node-role.kubernetes.io/control-plane\":\"true\"}'"
    "--set tolerations[0].key=node-role.kubernetes.io/control-plane"
    "--set tolerations[0].operator=Exists"
    "--set tolerations[0].effect=NoSchedule"
    "--set resources.requests.cpu=50m"
    "--set resources.requests.memory=64Mi"
    "--set resources.limits.cpu=200m"
    "--set resources.limits.memory=128Mi"
  ];

  kubeVipPostDeploy = ''
    ${kubectl} rollout status daemonset kube-vip -n kube-system --timeout=300s
  '';

  mkIPPool = location: pool: ''
    ---
    apiVersion: cilium.io/v2
    kind: CiliumLoadBalancerIPPool
    metadata:
      name: lb-pool-${location}
    spec:
      blocks:
        - start: ${pool.start}
          stop: ${pool.stop}
      serviceSelector:
        matchLabels:
          loadbalancer.${location}.enabled: "true"
  '';
in
  lib.mkIf lb.enabled {
    systemd.services.helm-deploy-kube-vip = lib.mkIf isInit (mkHelmService {
      name = "kube-vip";
      release = "kube-vip";
      namespace = "kube-system";
      chart = "kube-vip/kube-vip";
      version = versions.kubeVip;
      extraArgs = kubeVipArgs;
      postDeploy = kubeVipPostDeploy;
    });

    systemd.services.cilium-lb-pools = lib.mkIf isInit {
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5m";
      };

      script = ''
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
        ${log}
        mkdir -p /var/lib/cluster-manifests

        cat > /var/lib/cluster-manifests/pools.yaml << 'EOF'
        ${lib.concatStrings (lib.mapAttrsToList mkIPPool lb.pools)}
        EOF

        ${kubectl} apply -f /var/lib/cluster-manifests/pools.yaml
      '';
    };
  }
