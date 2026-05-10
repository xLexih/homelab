{
  pkgs,
  lib,
  clusterConfig,
  ...
}: let
  nodeNames = builtins.attrNames clusterConfig.nodes;

  nodeIp = n: let
    net = clusterConfig.nodes.${n}.network;
  in
    if net.endpoint != null
    then net.endpoint
    else net.lanIP;
  nodePort = n: let
    net = clusterConfig.nodes.${n}.network;
  in
    if net.sshPort != null
    then toString net.sshPort
    else "22";
  nodeUser = n: let
    net = clusterConfig.nodes.${n}.network;
  in
    if net.sshUser != null
    then net.sshUser
    else "nixos";
  nodeWgIP = n: clusterConfig.nodes.${n}.network.wgIP;

  mkResolver = name: attrFunc: let
    cases = lib.concatMapStringsSep "\n        " (n: "${n}) echo '${attrFunc n}' ;;") nodeNames;
  in ''
    resolve_${name}() {
      case "$1" in
        ${cases}
        *) echo "Unknown node: $1" >&2; exit 1 ;;
      esac
    }
  '';

  sshBase = ''-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5'';
in
  pkgs.writeShellScriptBin "get-kubeconfig" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${mkResolver "ip" nodeIp}
    ${mkResolver "port" nodePort}
    ${mkResolver "user" nodeUser}
    ${mkResolver "wgip" nodeWgIP}

    usage() {
      echo "Usage: get-kubeconfig <node> [ssh-key]"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
    }

    node="''${1:-}"
    key="''${2:-}"

    if [[ -z $node ]]; then
      echo "ERROR: node name required" >&2
      usage
      exit 1
    fi

    if [[ -n $key ]] && [[ ! -f $key ]]; then
      log "ERROR" "SSH key not found: $key"
      exit 1
    fi

    ip=$(resolve_ip "$node")
    port=$(resolve_port "$node")
    user=$(resolve_user "$node")
    wgIP=$(resolve_wgip "$node")

    KEY_OPT=""
    [[ -n $key ]] && KEY_OPT="-i $key"

    log get-kubeconfig "Fetching from $user@$ip:$port"
    mkdir -p ~/.kube

    ${pkgs.openssh}/bin/scp -P "$port" ${sshBase} $KEY_OPT "$user@$ip:/etc/rancher/k3s/k3s.yaml" /tmp/k3s-tmp.yaml
    sed "s/$wgIP/127.0.0.1/g" /tmp/k3s-tmp.yaml > ~/.kube/config
    rm -f /tmp/k3s-tmp.yaml
    chmod 600 ~/.kube/config

    log get-kubeconfig "Ready — KUBECONFIG=~/.kube/config"
    echo "To tunnel the API server: ssh -L 6443:$wgIP:6443 -p $port $KEY_OPT $user@$ip"
  ''
