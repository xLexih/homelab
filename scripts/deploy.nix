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
  initNode = helpers.initNode;

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

  mkResolver = attributeName: func: let
    cases = lib.concatMapStringsSep "\n        " (n: "${n}) echo '${func n}' ;;") nodeNames;
  in ''
    resolve_${attributeName}() {
      case "$1" in
        ${cases}
        *) echo "Unknown node: $1" >&2; exit 1 ;;
      esac
    }
  '';

  date = "${pkgs.coreutils}/bin/date";
  mktemp = "${pkgs.coreutils}/bin/mktemp";
  install = "${pkgs.coreutils}/bin/install";
  ssh = "${pkgs.openssh}/bin/ssh";
in
  pkgs.writeShellScriptBin "deploy" ''
    set -euo pipefail
    DATE=${date}
    MKTEMP=${mktemp}
    INSTALL=${install}
    SSH=${ssh}

    log() { echo "[$($DATE '+%H:%M:%S')] [$1] $2"; }

    ${mkResolver "ip" nodeIp}
    ${mkResolver "port" nodePort}
    ${mkResolver "user" nodeUser}

    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=VERBOSE"

    require_key() {
      if [[ -n "''${1:-}" ]] && [[ ! -f "''${1}" ]]; then
        log "ERROR" "SSH key not found: $1"
        exit 1
      fi
    }

    # Parse options using explicit checks (avoids case statement portability issues).
    # Variables: node, key, jump, jump_key, jump_port, user, host, port
    parse_args() {
      node=""; key=""; jump=""; jump_key=""; jump_port=""; user=""; host=""; port=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
          shift
          break
        elif [[ "$1" == "-i" || "$1" == "--identity" ]]; then
          key="$2"; shift 2
        elif [[ "$1" == "-j" || "$1" == "--jump" ]]; then
          jump="$2"; shift 2
        elif [[ "$1" == "--jump-key" ]]; then
          jump_key="$2"; shift 2
        elif [[ "$1" == "--jump-port" ]]; then
          jump_port="$2"; shift 2
        elif [[ "$1" == "-u" || "$1" == "--user" ]]; then
          user="$2"; shift 2
        elif [[ "$1" == "-H" || "$1" == "--host" ]]; then
          host="$2"; shift 2
        elif [[ "$1" == "-p" || "$1" == "--port" ]]; then
          port="$2"; shift 2
        elif [[ "$1" == -* ]]; then
          echo "Unknown option: $1" >&2; return 1
        else
          if [[ -z $node ]]; then
            node="$1"
          else
            echo "Unexpected argument: $1" >&2; return 1
          fi
          shift
        fi
      done
    }

    resolve_target() {
      local node="$1"
      TARGET_IP="''${host:-$(resolve_ip "$node")}"
      TARGET_PORT="''${port:-$(resolve_port "$node")}"
      TARGET_USER="''${user:-$(resolve_user "$node")}"
      TARGET_HOST="$TARGET_USER@$TARGET_IP"
    }

    build_jump_opt() {
      if [[ -z "''${jump:-}" ]]; then
        JUMP_OPT=""
        return
      fi
      local jport="''${jump_port:-22}"
      if [[ -n "''${jump_key:-}" ]]; then
        JUMP_OPT="-o ProxyCommand='$SSH -i $jump_key -p $jport -W %h:%p $jump'"
      else
        JUMP_OPT="-J $jump"
      fi
    }

    check_host() {
      local ssh_cmd="$SSH $SSH_OPTS -p $TARGET_PORT $JUMP_OPT ''${KEY_OPT:-} $TARGET_HOST"
      log "$node" "Checking connectivity..."
      if ! eval "$ssh_cmd true" 2>/dev/null; then
        log "$node" "ERROR: cannot reach $TARGET_HOST"
        return 1
      fi
    }

    usage() {
      echo "Usage: deploy <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  init    <node> [options]   Initial deployment"
      echo "  rebuild <node> [options]   Update existing node"
      echo "  all     [options]           Rebuild all nodes"
      echo "  rollback <node> [options]   Rollback last generation"
      echo ""
      echo "Options (init/rebuild/rollback):"
      echo "  -i, --identity <key>  SSH private key"
      echo "  -u, --user <user>     SSH user (overrides config)"
      echo "  -H, --host <host>     Target IP/hostname (overrides config)"
      echo "  -p, --port <port>     SSH port (overrides config)"
      echo "  -j, --jump <user@host> Bastion/jump host"
      echo "  --jump-key <key>      SSH key for jump host"
      echo "  --jump-port <port>    SSH port for jump host (default 22)"
      echo "  --parallel            Rebuild all nodes in parallel"
      echo "  --                     End option parsing"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
      echo "Init:  ${initNode} (must be deployed first)"
    }

    cmd_init() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { echo "ERROR: node name required" >&2; usage; exit 1; }

      require_key "$key"
      resolve_target "$node"
      build_jump_opt
      KEY_OPT="''${key:+-i $key}"

      log init "$node -> $TARGET_HOST:$TARGET_PORT ($([[ -n $jump ]] && echo "via $jump" || echo "direct"))"
      check_host || exit 1

      tmp=$($MKTEMP -d)
      trap 'rm -rf "$tmp"' EXIT
      $INSTALL -d -m 755 "$tmp/etc/ssh"
      $INSTALL -m 600 "keys/hosts/$node/ssh_host_ed25519_key"     "$tmp/etc/ssh/"
      $INSTALL -m 644 "keys/hosts/$node/ssh_host_ed25519_key.pub" "$tmp/etc/ssh/"

      ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
        --ssh-option StrictHostKeyChecking=no \
        --ssh-option UserKnownHostsFile=/dev/null \
        --ssh-option LogLevel=VERBOSE \
        --ssh-option Port="$TARGET_PORT" \
        $KEY_OPT \
        --extra-files "$tmp" \
        --flake ".#$node" \
        "$TARGET_HOST"
    }

    cmd_rebuild() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { echo "ERROR: node name required" >&2; usage; exit 1; }

      require_key "$key"
      resolve_target "$node"
      build_jump_opt
      KEY_OPT="''${key:+-i $key}"

      log rebuild "$node -> $TARGET_HOST:$TARGET_PORT ($([[ -n $jump ]] && echo "via $jump" || echo "direct"))"
      check_host || exit 1

      export NIX_SSHOPTS="$SSH_OPTS -p $TARGET_PORT $JUMP_OPT $KEY_OPT"
      nixos-rebuild switch --flake ".#$node" --target-host "$TARGET_HOST"
    }

    cmd_all() {
      local key=""
      local parallel=false
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--parallel" ]]; then
          parallel=true; shift
        elif [[ "$1" == "-i" || "$1" == "--identity" ]]; then
          key="$2"; shift 2
        elif [[ "$1" == -* ]]; then
          echo "Unknown option: $1" >&2; usage; exit 1
        else
          echo "Unexpected argument: $1" >&2; usage; exit 1
        fi
      done

      require_key "$key"

      deploy_node() {
        local n="$1" k="$2"
        log all "$n"
        cmd_rebuild "$n" -i "$k"
      }

      if $parallel; then
        for n in ${lib.concatStringsSep " " nodeNames}; do
          deploy_node "$n" "$key" &
        done
        wait
      else
        for n in ${lib.concatStringsSep " " nodeNames}; do
          deploy_node "$n" "$key"
        done
      fi
    }

    cmd_rollback() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { echo "ERROR: node name required" >&2; usage; exit 1; }

      require_key "$key"
      resolve_target "$node"
      build_jump_opt
      KEY_OPT="''${key:+-i $key}"

      log rollback "$node -> $TARGET_HOST:$TARGET_PORT"
      check_host || exit 1

      export NIX_SSHOPTS="$SSH_OPTS -p $TARGET_PORT $JUMP_OPT $KEY_OPT"
      nixos-rebuild switch --rollback --flake ".#$node" --target-host "$TARGET_HOST"
    }

    case "''${1:-}" in
      init)     shift; cmd_init     "$@" ;;
      rebuild)  shift; cmd_rebuild  "$@" ;;
      all)      shift; cmd_all      "$@" ;;
      rollback) shift; cmd_rollback "$@" ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
