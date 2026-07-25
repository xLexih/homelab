{
  pkgs,
  lib,
}: let
  kubectl = "${pkgs.kubectl}/bin/kubectl";
  helm = "${pkgs.kubernetes-helm}/bin/helm";
  jq = "${pkgs.jq}/bin/jq";
  awk = "${pkgs.gawk}/bin/awk";
  stateDir = "/var/lib/helm-deploy";

  mkStateFileName = release: version: extras: let
    configHash = builtins.hashString "sha256" (lib.concatStringsSep "::" ([version] ++ extras));
  in "${release}-${builtins.substring 0 16 configHash}";

  log = ''log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }'';

  waitForApi = ''
    for i in $(seq 1 36); do
      if ${kubectl} get --raw /healthz 2>/dev/null | grep -q "ok"; then
        log api "Ready"
        break
      fi
      [ "$i" -eq 36 ] && { log api "ERROR: not ready after 3m"; exit 1; }
      sleep 5
    done
  '';

  helmCleanup = ''
    cleanup_helm_release() {
      local release="$1" namespace="$2"
      local status
      status=$(${helm} status "$release" -n "$namespace" 2>&1) || {
        log "$release" "Not found, will install"
        return 0
      }
      local current
      current=$(echo "$status" | grep "^STATUS:" | ${awk} '{print $2}')
      [ "$current" = "deployed" ] && { log "$release" "Already deployed"; return 0; }

      if [ "$current" = "pending-upgrade" ] || [ "$current" = "pending-install" ] || \
         [ "$current" = "pending-rollback" ] || [ "$current" = "failed" ]; then
        log "$release" "Stuck: $current"
        local last_good
        last_good=$(${helm} history "$release" -n "$namespace" 2>&1 | ${awk} '$3 == "deployed" {print $1}' | tail -1)
        if [ -n "$last_good" ]; then
          log "$release" "Rolling back to revision $last_good"
          ${helm} rollback "$release" "$last_good" -n "$namespace" --timeout 2m && return 0
        fi
        log "$release" "Uninstalling"
        ${helm} uninstall "$release" -n "$namespace" --timeout 1m 2>/dev/null || true
      fi
    }
  '';

  helmDeploy = ''
    helm_deploy() {
      local release="$1" namespace="$2" chart="$3" version="$4"
      shift 4
      log "$release" "Deploying $chart:$version"
      ${helm} upgrade --install "$release" "$chart" \
        --namespace "$namespace" \
        --version "$version" \
        --create-namespace \
        "$@" \
        --atomic \
        --cleanup-on-fail \
        --history-max 5 \
        --wait-for-jobs \
        --timeout 10m \
        || { log "$release" "ERROR: Deploy failed"; exit 1; }
      log "$release" "Deployed"
    }
  '';
in {
  versions = {
    cilium = "1.19.3";
    longhorn = "v1.11.1";
    kubeVip = "0.9.8";
    dockerRegistry = "v3.0.0";
    dockerRegistryUI = "1.1.4";
    nvidiaDevicePlugin = "0.19.1";
  };

  helmRepos = [
    {
      name = "cilium";
      url = "https://helm.cilium.io/";
    }
    {
      name = "longhorn";
      url = "https://charts.longhorn.io/";
    }
    {
      name = "kube-vip";
      url = "https://kube-vip.github.io/helm-charts/";
    }
    {
      name = "twuni";
      url = "https://twuni.github.io/docker-registry.helm";
    }
    {
      name = "joxit";
      url = "https://helm.joxit.dev/";
    }
    {
      name = "nvdp";
      url = "https://nvidia.github.io/k8s-device-plugin";
    }
  ];

  inherit kubectl helm jq log;
  inherit mkStateFileName stateDir;
  inherit waitForApi helmCleanup helmDeploy;

  mkHelmService = {
    name,
    release,
    namespace,
    chart,
    version,
    extraArgs ? [],
    preDeploy ? "",
    postDeploy ? "",
  }: let
    stateFile = "${stateDir}/${mkStateFileName release version extraArgs}.deployed";
    argsArrayStr = lib.concatStringsSep " " extraArgs;
  in {
    description = "Deploy ${name}";
    wantedBy = ["multi-user.target"];
    unitConfig.ConditionPathExists = "!${stateFile}";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "no";
      TimeoutStartSec = "15m";
    };
    script = ''
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
      mkdir -p ${stateDir}

      ${log}

      ${waitForApi}
      ${helmCleanup}
      ${helmDeploy}

      cleanup_helm_release "${release}" "${namespace}"

      ${preDeploy}

      helm_deploy "${release}" "${namespace}" "${chart}" "${version}" ${argsArrayStr}

      ${postDeploy}

      touch "${stateFile}"
    '';
  };
}
