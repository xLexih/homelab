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
  knownHostsFile = pkgs.writeText "cluster-${clusterConfig.name}-known-hosts" (helpers.mkKnownHosts ../secrets);
in
  pkgs.writeShellScriptBin "get-kubeconfig" ''
    set -euo pipefail
    SSH=${pkgs.openssh}/bin/ssh
    SCP=${pkgs.openssh}/bin/scp
    KNOWN_HOSTS=${knownHostsFile}
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}
    ${helpers.mkResolver "wgip" helpers.nodeWgIP}

    usage() {
      echo "Usage: get-kubeconfig <node> [ssh-key]"
      echo ""
      echo "Writes ~/.kube/${clusterConfig.name}.yaml without replacing other kubeconfigs."
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
    }

    [[ "''${1:-}" != -h && "''${1:-}" != --help ]] || { usage; exit 0; }
    node="''${1:-}"
    key="''${2:-}"
    [[ -n "$node" ]] || { usage; exit 1; }
    [[ -z "$key" || -f "$key" ]] || { log get-kubeconfig "ERROR: Key not found: $key"; exit 1; }

    ip=$(resolve_ip "$node")
    port=$(resolve_port "$node")
    user=$(resolve_user "$node")
    wg_ip=$(resolve_wgip "$node")
    key_args=()
    [[ -z "$key" ]] || key_args=(-i "$key")
    tmp=$(${pkgs.coreutils}/bin/mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    output="$HOME/.kube/${clusterConfig.name}.yaml"

    log get-kubeconfig "Fetching from $user@$ip:$port"
    mkdir -p "$HOME/.kube"
    "$SCP" -P "$port" ${helpers.sshOpts} \
      -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" \
      "''${key_args[@]}" "$user@$ip:/etc/rancher/k3s/k3s.yaml" "$tmp/remote.yaml"
    ${pkgs.gnused}/bin/sed "s|https://$wg_ip:|https://127.0.0.1:|" "$tmp/remote.yaml" > "$tmp/config"
    ${pkgs.coreutils}/bin/install -m 0600 "$tmp/config" "$output"

    log get-kubeconfig "Ready — KUBECONFIG=$output"
    printf 'Tunnel: %q ' "$SSH" -L "6443:$wg_ip:6443" -p "$port" \
      -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" \
      "''${key_args[@]}" "$user@$ip"
    printf '\n'
  ''
