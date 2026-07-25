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
in
  pkgs.writeShellScriptBin "image" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}

    exec_on() {
      local node="$1" key="$2"; shift 2
      local ip=$(resolve_ip "$node") port=$(resolve_port "$node") user=$(resolve_user "$node")
      local key_opt=""; [[ -n "$key" ]] && key_opt="-i $key"
      ${ssh} ${helpers.sshOpts} -p "$port" $key_opt "$user@$ip" -- "$@"
    }

    run_on() {
      local target="$1" key="$2"; shift 2
      local nodes
      [[ "$target" == "all" ]] \
        && nodes="${lib.concatStringsSep " " nodeNames}" \
        || nodes="$target"
      for node in $nodes; do
        exec_on "$node" "$key" "$@"
      done
    }

    usage() {
      echo "Usage: image <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  add  <file.tar[.gz]> [node|all] [key]  Import image"
      echo "  list [node|all] [key]                   List images"
      echo "  rm   <image-ref> [node|all] [key]       Remove image"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
    }

    case "''${1:-}" in
      add|import)
        file="''${2:-}"; target="''${3:-all}"; key="''${4:-}"
        [[ -z "$file" ]] && { usage; exit 1; }
        [[ -f "$file" ]] || { log image "Not found: $file"; exit 1; }
        [[ -n "$key" && ! -f "$key" ]] && { log ERROR "Key not found: $key"; exit 1; }

        if [[ "$file" == *.tar.gz || "$file" == *.tgz ]]; then
          tmp=$(mktemp --suffix=.tar)
          trap 'rm -f "$tmp"' EXIT
          gunzip -c "$file" > "$tmp"
          file="$tmp"
        fi
        run_on "$target" "$key" k3s ctr images import - < "$file"
        ;;
      list|ls)
        target="''${2:-all}"; key="''${3:-}"
        [[ -n "$key" && ! -f "$key" ]] && { log ERROR "Key not found: $key"; exit 1; }
        run_on "$target" "$key" k3s ctr images list -q | grep -v sha256 | sort
        ;;
      rm|remove)
        ref="''${2:-}"; target="''${3:-all}"; key="''${4:-}"
        [[ -z "$ref" ]] && { usage; exit 1; }
        [[ -n "$key" && ! -f "$key" ]] && { log ERROR "Key not found: $key"; exit 1; }
        run_on "$target" "$key" k3s ctr images rm "$ref"
        ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
