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
  pkgs.writeShellScriptBin "image" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${mkResolver "ip" nodeIp}
    ${mkResolver "port" nodePort}
    ${mkResolver "user" nodeUser}

    require_key() {
      if [[ -n "''${1:-}" ]] && [[ ! -f "''${1}" ]]; then
        log "ERROR" "SSH key not found: $1"
        exit 1
      fi
    }

    exec_on_node() {
      local node="$1" key="$2"; shift 2
      local ip=$(resolve_ip "$node") port=$(resolve_port "$node") user=$(resolve_user "$node")
      local key_opt=""; [[ -n "$key" ]] && key_opt="-i $key"
      ssh ${sshBase} -p "$port" $key_opt "$user@$ip" -- "$@"
    }

    run_on() {
      local target="$1" key="$2"; shift 2
      local nodes
      if [[ "$target" == "all" ]]; then
        nodes="${lib.concatStringsSep " " nodeNames}"
      else
        nodes="$target"
      fi
      for node in $nodes; do
        exec_on_node "$node" "$key" "$@"
      done
    }

    usage() {
      echo "Usage: image <add|list|rm> [args...]"
      echo ""
      echo " add <file.tar[.gz]> [node|all] [ssh-key]   Import image"
      echo " list [node|all] [ssh-key]                  List images"
      echo " rm  <image-ref> [node|all] [ssh-key]       Remove image"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
    }

    case "''${1:-}" in
      add|import)
        file="''${2:-}"; target="''${3:-all}"; key="''${4:-}"
        [[ -z "$file" ]] && { echo "ERROR: file required" >&2; usage; exit 1; }
        [[ -f "$file" ]]   || { log image "File not found: $file"; exit 1; }
        require_key "$key"

        decompressed=""
        if [[ "$file" == *.tar.gz || "$file" == *.tgz ]]; then
          decompressed=$(mktemp --suffix=.tar)
          gunzip -c "$file" > "$decompressed"
          file="$decompressed"
          trap 'rm -f "$decompressed"' EXIT
        fi

        run_on "$target" "$key" k3s ctr images import - < "$file"
        ;;
      list|ls)
        target="''${2:-all}"; key="''${3:-}"
        require_key "$key"
        run_on "$target" "$key" k3s ctr images list -q | grep -v sha256 | sort
        ;;
      rm|remove)
        ref="''${2:-}"; target="''${3:-all}"; key="''${4:-}"
        [[ -z "$ref" ]] && { echo "ERROR: image reference required" >&2; usage; exit 1; }
        require_key "$key"
        run_on "$target" "$key" k3s ctr images rm "$ref"
        ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
