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
  pkgs.writeShellScriptBin "image" ''
    set -euo pipefail
    SSH=${pkgs.openssh}/bin/ssh
    KNOWN_HOSTS=${knownHostsFile}
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}

    exec_on() {
      local node="$1" key="$2"
      shift 2
      local ip port user
      local key_args=()
      ip=$(resolve_ip "$node")
      port=$(resolve_port "$node")
      user=$(resolve_user "$node")
      [[ -z "$key" ]] || key_args=(-i "$key")
      "$SSH" ${helpers.sshOpts} \
        -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS" \
        -p "$port" "''${key_args[@]}" "$user@$ip" -- "$@"
    }

    targets() {
      if [[ "$1" == all ]]; then
        echo "${lib.concatStringsSep " " nodeNames}"
      else
        resolve_ip "$1" >/dev/null
        echo "$1"
      fi
    }

    run_on() {
      local target="$1" key="$2"
      shift 2
      local node
      for node in $(targets "$target"); do
        exec_on "$node" "$key" "$@"
      done
    }

    import_on() {
      local file="$1" target="$2" key="$3" node
      for node in $(targets "$target"); do
        log image "Importing on $node"
        exec_on "$node" "$key" k3s ctr images import - < "$file"
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
        [[ -n "$file" ]] || { usage; exit 1; }
        [[ -f "$file" ]] || { log image "Not found: $file"; exit 1; }
        [[ -z "$key" || -f "$key" ]] || { log image "Key not found: $key"; exit 1; }
        if [[ "$file" == *.tar.gz || "$file" == *.tgz ]]; then
          tmp=$(${pkgs.coreutils}/bin/mktemp --suffix=.tar)
          trap 'rm -f "$tmp"' EXIT
          ${pkgs.gzip}/bin/gunzip -c "$file" > "$tmp"
          file="$tmp"
        fi
        import_on "$file" "$target" "$key"
        ;;
      list|ls)
        target="''${2:-all}"; key="''${3:-}"
        [[ -z "$key" || -f "$key" ]] || { log image "Key not found: $key"; exit 1; }
        run_on "$target" "$key" k3s ctr images list -q | ${pkgs.gnused}/bin/sed '/sha256/d' | sort
        ;;
      rm|remove)
        ref="''${2:-}"; target="''${3:-all}"; key="''${4:-}"
        [[ -n "$ref" ]] || { usage; exit 1; }
        [[ -z "$key" || -f "$key" ]] || { log image "Key not found: $key"; exit 1; }
        run_on "$target" "$key" k3s ctr images rm "$ref"
        ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
