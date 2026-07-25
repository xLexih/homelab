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
  }
