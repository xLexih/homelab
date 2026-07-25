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

  date = "${pkgs.coreutils}/bin/date";
  mktemp = "${pkgs.coreutils}/bin/mktemp";
  install = "${pkgs.coreutils}/bin/install";
  rm = "${pkgs.coreutils}/bin/rm";
  ssh = "${pkgs.openssh}/bin/ssh";
in
  pkgs.writeShellScriptBin "deploy" ''
    set -euo pipefail
    DATE=${date}
    MKTEMP=${mktemp}
    INSTALL=${install}
    RM=${rm}
    SSH=${ssh}

    log() { echo "[$($DATE '+%H:%M:%S')] [$1] $2"; }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}
    ${helpers.mkResolver "platform" (n: clusterConfig.nodes.${n}.platform)}

    SSH_OPTS="${helpers.sshOpts} -o LogLevel=VERBOSE"

    require_key() {
      if [[ -n "''${1:-}" ]] && [[ ! -f "''${1}" ]]; then
        log ERROR "SSH key not found: $1"
        exit 1
      fi
    }

    parse_args() {
      node=""; key=""; jump=""; jump_key=""; jump_port=""; user=""; host=""; port=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then shift; break
        elif [[ "$1" == "-i" || "$1" == "--identity" ]]; then key="$2"; shift 2
        elif [[ "$1" == "-j" || "$1" == "--jump" ]]; then jump="$2"; shift 2
        elif [[ "$1" == "--jump-key" ]]; then jump_key="$2"; shift 2
        elif [[ "$1" == "--jump-port" ]]; then jump_port="$2"; shift 2
        elif [[ "$1" == "-u" || "$1" == "--user" ]]; then user="$2"; shift 2
        elif [[ "$1" == "-H" || "$1" == "--host" ]]; then host="$2"; shift 2
        elif [[ "$1" == "-p" || "$1" == "--port" ]]; then port="$2"; shift 2
        elif [[ "$1" == -* ]]; then echo "Unknown option: $1" >&2; return 1
        else
          [[ -z $node ]] && node="$1" || { echo "Unexpected: $1" >&2; return 1; }
          shift
        fi
      done
    }

    resolve_target() {
      TARGET_IP="''${host:-$(resolve_ip "$1")}"
      TARGET_PORT="''${port:-$(resolve_port "$1")}"
      TARGET_USER="''${user:-$(resolve_user "$1")}"
      TARGET_HOST="$TARGET_USER@$TARGET_IP"
    }

    build_ssh_cmd() {
      local jump_opt=""
      if [[ -n "''${jump:-}" ]]; then
        if [[ -n "''${jump_key:-}" ]]; then
          jump_opt="-o ProxyCommand='$SSH -i $jump_key -p ''${jump_port:-22} -W %h:%p $jump'"
        else
          jump_opt="-J $jump"
        fi
      fi
      SSH_CMD="$SSH $SSH_OPTS -p $TARGET_PORT $jump_opt ''${key:+-i $key}"
    }

    check_host() {
      log "$node" "Checking $TARGET_HOST:$TARGET_PORT..."
      if ! eval "$SSH_CMD $TARGET_HOST true" 2>/dev/null; then
        log "$node" "ERROR: unreachable"; return 1
      fi
    }

    bootstrap_lxc_host_key() {
      [[ $(resolve_platform "$node") == lxc ]] || return 0
      [[ -f ~/.ssh/k3s-admin ]] || {
        log "$node" "ERROR: ~/.ssh/k3s-admin is required to decrypt the managed LXC host key"
        return 1
      }

      local tmp
      tmp=$($MKTEMP -d)
      trap '$RM -rf "$tmp"' EXIT
      ${pkgs.age}/bin/age -d -i ~/.ssh/k3s-admin \
        "secrets/hosts/$node/ssh-key.age" > "$tmp/ssh_host_ed25519_key"
      cp "secrets/hosts/$node/ssh-key.pub" "$tmp/ssh_host_ed25519_key.pub"

      log "$node" "Installing managed SSH host identity for age secrets"
      eval "$SSH_CMD $TARGET_HOST 'install -m 0600 /dev/stdin /etc/ssh/.ssh_host_ed25519_key.new'" \
        < "$tmp/ssh_host_ed25519_key"
      eval "$SSH_CMD $TARGET_HOST 'install -m 0644 /dev/stdin /etc/ssh/.ssh_host_ed25519_key.pub.new'" \
        < "$tmp/ssh_host_ed25519_key.pub"
      eval "$SSH_CMD $TARGET_HOST 'mv /etc/ssh/.ssh_host_ed25519_key.new /etc/ssh/ssh_host_ed25519_key && mv /etc/ssh/.ssh_host_ed25519_key.pub.new /etc/ssh/ssh_host_ed25519_key.pub'"
      $RM -rf "$tmp"
      trap - EXIT
    }

    usage() {
      echo "Usage: deploy <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  init     <node> [opts]  Initial deployment (nixos-anywhere)"
      echo "  rebuild  <node> [opts]  Update existing node"
      echo "  all      [opts]         Rebuild all nodes"
      echo "  rollback <node> [opts]  Rollback to previous generation"
      echo ""
      echo "Options:"
      echo "  -i, --identity <key>   SSH private key"
      echo "  -u, --user <user>      SSH user override"
      echo "  -H, --host <host>      Target IP override"
      echo "  -p, --port <port>      SSH port override"
      echo "  -j, --jump <host>      Jump host"
      echo "  --jump-key <key>       Jump host SSH key"
      echo "  --jump-port <port>     Jump host port"
      echo "  --parallel             Rebuild all in parallel"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
      echo "Init:  ${helpers.initNode}"
    }

    cmd_init() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { usage; exit 1; }
      if [[ $(resolve_platform "$node") == lxc ]]; then
        log "$node" "ERROR: LXC nodes must be pre-installed and deployed with 'rebuild'"
        exit 1
      fi
      require_key "$key"
      resolve_target "$node"
      build_ssh_cmd
      check_host || exit 1

      tmp=$($MKTEMP -d)
      trap 'rm -rf "$tmp"' EXIT
      $INSTALL -d -m 755 "$tmp/etc/ssh"

      ${pkgs.age}/bin/age -d -i ~/.ssh/k3s-admin "secrets/hosts/$node/ssh-key.age" \
        > "$tmp/etc/ssh/ssh_host_ed25519_key"
      chmod 600 "$tmp/etc/ssh/ssh_host_ed25519_key"
      cp "secrets/hosts/$node/ssh-key.pub" "$tmp/etc/ssh/ssh_host_ed25519_key.pub"

      ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
        --ssh-option StrictHostKeyChecking=no \
        --ssh-option UserKnownHostsFile=/dev/null \
        --ssh-option LogLevel=VERBOSE \
        --ssh-option Port="$TARGET_PORT" \
        ''${key:+--ssh-option "IdentityFile=$key"} \
        --extra-files "$tmp" \
        --flake ".#$node" \
        "$TARGET_HOST"
    }

    set_nix_ssh_opts() {
      export NIX_SSHOPTS="$SSH_OPTS -p $TARGET_PORT ''${key:+-i $key}"
    }

    cmd_rebuild() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { usage; exit 1; }
      require_key "$key"
      resolve_target "$node"
      build_ssh_cmd

      log rebuild "$node -> $TARGET_HOST:$TARGET_PORT"
      check_host || exit 1
      bootstrap_lxc_host_key || exit 1

      set_nix_ssh_opts
      if [[ $(resolve_platform "$node") == lxc ]]; then
        nixos-rebuild boot --flake ".#$node" --target-host "$TARGET_HOST"
        log "$node" "LXC generation staged; reboot the container from its host to activate it"
      else
        nixos-rebuild switch --flake ".#$node" --target-host "$TARGET_HOST"
      fi
    }

    cmd_all() {
      local key="" parallel=false user="" host="" port=""
      while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--parallel" ]]; then parallel=true; shift
        elif [[ "$1" == "-i" || "$1" == "--identity" ]]; then key="$2"; shift 2
        elif [[ "$1" == "-u" || "$1" == "--user" ]]; then user="$2"; shift 2
        elif [[ "$1" == "-H" || "$1" == "--host" ]]; then host="$2"; shift 2
        elif [[ "$1" == "-p" || "$1" == "--port" ]]; then port="$2"; shift 2
        else echo "Unknown: $1" >&2; usage; exit 1
        fi
      done
      require_key "$key"

      if $parallel; then
        for n in ${lib.concatStringsSep " " nodeNames}; do
          cmd_rebuild "$n" ''${key:+-i "$key"} ''${user:+-u "$user"} ''${host:+-H "$host"} ''${port:+-p "$port"} &
        done
        wait
      else
        for n in ${lib.concatStringsSep " " nodeNames}; do
          cmd_rebuild "$n" ''${key:+-i "$key"} ''${user:+-u "$user"} ''${host:+-H "$host"} ''${port:+-p "$port"}
        done
      fi
    }

    cmd_rollback() {
      parse_args "$@" || { usage; exit 1; }
      [[ -z $node ]] && { usage; exit 1; }
      require_key "$key"
      resolve_target "$node"
      build_ssh_cmd

      log rollback "$node -> $TARGET_HOST:$TARGET_PORT"
      check_host || exit 1

      set_nix_ssh_opts
      if [[ $(resolve_platform "$node") == lxc ]]; then
        nixos-rebuild boot --rollback --flake ".#$node" --target-host "$TARGET_HOST"
        log "$node" "LXC rollback staged; reboot the container from its host to activate it"
      else
        nixos-rebuild switch --rollback --flake ".#$node" --target-host "$TARGET_HOST"
      fi
    }

    case "''${1:-}" in
      init)     shift; cmd_init "$@" ;;
      rebuild)  shift; cmd_rebuild "$@" ;;
      all)      shift; cmd_all "$@" ;;
      rollback) shift; cmd_rollback "$@" ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
