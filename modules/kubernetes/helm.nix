{
  lib,
  helpers,
  helmDefaults,
  nodeConfig,
  ...
}: let
  isInit = nodeConfig.init;
  isMaster = helpers.hasRole "master" nodeConfig;
in
  lib.mkIf (isInit && isMaster) {
    systemd.services.helm-repo-setup = {
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      requires = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = "5m";
      };
      script = ''
        ${lib.concatMapStrings (r: "${helmDefaults.helm} repo add ${r.name} ${r.url} --force-update\n") helmDefaults.helmRepos}
        ${helmDefaults.helm} repo update
      '';
    };

    systemd.services.helm-deploy-cilium = {
      after = ["k3s.service" "helm-repo-setup.service"];
      requires = ["k3s.service"];
      before = [
        "helm-deploy-kube-vip.service"
        "helm-deploy-longhorn.service"
        "deploy-nvidia-device-plugin.service"
      ];
    };

    systemd.services.helm-deploy-kube-vip = {
      after = ["k3s.service" "helm-repo-setup.service" "helm-deploy-cilium.service"];
      requires = ["k3s.service"];
    };

    systemd.services.cilium-lb-pools = {
      after = ["helm-deploy-cilium.service" "helm-deploy-kube-vip.service"];
      requires = ["helm-deploy-cilium.service"];
    };

    systemd.services.helm-deploy-longhorn = {
      after = ["k3s.service" "helm-repo-setup.service" "helm-deploy-cilium.service"];
      requires = ["k3s.service"];
    };

    systemd.services.registry-rwx-storageclass = {
      after = ["k3s.service" "helm-deploy-longhorn.service"];
      requires = ["helm-deploy-longhorn.service"];
    };

    systemd.services.helm-deploy-registry = {
      after = ["k3s.service" "helm-repo-setup.service" "registry-rwx-storageclass.service"];
      requires = ["k3s.service"];
    };

    systemd.services.helm-deploy-registry-ui = {
      after = ["k3s.service" "helm-repo-setup.service" "helm-deploy-registry.service"];
      requires = ["helm-deploy-registry.service"];
    };

    systemd.services.patch-coredns = {
      after = ["k3s.service" "helm-deploy-cilium.service"];
      requires = ["k3s.service"];
    };

    systemd.services.deploy-nvidia-device-plugin = {
      after = ["k3s.service" "helm-repo-setup.service" "helm-deploy-cilium.service"];
      requires = ["k3s.service"];
    };
  }
