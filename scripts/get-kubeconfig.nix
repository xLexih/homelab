{
  pkgs,
  lib,
  clusterConfig,
  ...
}: let
  helpers = import ../lib/helpers.nix {
    inherit lib;
    cluster = clusterConfig;
  };
  nodeNames = builtins.attrNames clusterConfig.nodes;
  ssh = "${pkgs.openssh}/bin/ssh";
  scp = "${pkgs.openssh}/bin/scp";
in
  pkgs.writeShellScriptBin "get-kubeconfig" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}
    ${helpers.mkResolver "wgip" helpers.nodeWgIP}

    usage() {
      echo "Usage: get-kubeconfig <node> [ssh-key]"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
    }

    node="''${1:-}"
    key="''${2:-}"

    [[ -n $node ]] || { usage; exit 1; }
    [[ -z $key || -f $key ]] || { log get-kubeconfig "ERROR: Key not found: $key"; exit 1; }

    ip=$(resolve_ip "$node")
    port=$(resolve_port "$node")
    user=$(resolve_user "$node")
    wgIP=$(resolve_wgip "$node")
    key_opt=""; [[ -n $key ]] && key_opt="-i $key"

    log get-kubeconfig "Fetching from $user@$ip:$port"
    mkdir -p ~/.kube

    ${scp} -P "$port" ${helpers.sshOpts} $key_opt \
      "$user@$ip:/etc/rancher/k3s/k3s.yaml" /tmp/k3s-tmp.yaml
    sed "s/$wgIP/127.0.0.1/g" /tmp/k3s-tmp.yaml > ~/.kube/config
    rm -f /tmp/k3s-tmp.yaml
    chmod 600 ~/.kube/config

    log get-kubeconfig "Ready — KUBECONFIG=~/.kube/config"
    echo "Tunnel: ${ssh} -L 6443:$wgIP:6443 -p $port $key_opt $user@$ip"
  ''
