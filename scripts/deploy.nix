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
  rebuildOrder = (builtins.filter (name: name != helpers.initNode) nodeNames) ++ [helpers.initNode];
  knownHostsFile = pkgs.writeText "cluster-${clusterConfig.name}-known-hosts" (helpers.mkKnownHosts ../secrets);
in
  pkgs.writeShellScriptBin "deploy" ''
    set -euo pipefail
    DATE=${pkgs.coreutils}/bin/date
    MKTEMP=${pkgs.coreutils}/bin/mktemp
    INSTALL=${pkgs.coreutils}/bin/install
    RM=${pkgs.coreutils}/bin/rm
    SSH=${pkgs.openssh}/bin/ssh
    NIX=${pkgs.nix}/bin/nix
    NIXOS_REBUILD=${pkgs.nixos-rebuild}/bin/nixos-rebuild
    KNOWN_HOSTS=${knownHostsFile}
    CLEANUP_TMP=""

    log() { echo "[$($DATE '+%H:%M:%S')] [$1] $2"; }
    cleanup_tmp() {
      [[ -z "$CLEANUP_TMP" ]] || "$RM" -rf -- "$CLEANUP_TMP"
    }

    ${helpers.mkResolver "ip" helpers.nodeIp}
    ${helpers.mkResolver "port" helpers.nodePort}
    ${helpers.mkResolver "user" helpers.nodeUser}
    ${helpers.mkResolver "platform" (name: clusterConfig.nodes.${name}.platform)}

    require_value() {
      [[ $# -ge 2 && -n "$2" ]] || {
        echo "Option $1 requires a value" >&2
        return 1
      }
    }

    require_key() {
      [[ -z "''${1:-}" || -f "$1" ]] || {
        log deploy "ERROR: SSH key not found: $1"
        exit 1
      }
    }

    parse_args() {
      node=""; key=""; jump=""; jump_key=""; jump_port=""; user=""; host=""; port=""; insecure=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --) shift; break ;;
          -i|--identity) require_value "$@" || return 1; key="$2"; shift 2 ;;
          -j|--jump) require_value "$@" || return 1; jump="$2"; shift 2 ;;
          --jump-key) require_value "$@" || return 1; jump_key="$2"; shift 2 ;;
          --jump-port) require_value "$@" || return 1; jump_port="$2"; shift 2 ;;
          -u|--user) require_value "$@" || return 1; user="$2"; shift 2 ;;
          -H|--host) require_value "$@" || return 1; host="$2"; shift 2 ;;
          -p|--port) require_value "$@" || return 1; port="$2"; shift 2 ;;
          --insecure-bootstrap) insecure=true; shift ;;
          -*) echo "Unknown option: $1" >&2; return 1 ;;
          *)
            [[ -z "$node" ]] || { echo "Unexpected argument: $1" >&2; return 1; }
            node="$1"
            shift
            ;;
        esac
      done
    }

    resolve_target() {
      TARGET_IP="''${host:-$(resolve_ip "$1")}"
      TARGET_PORT="''${port:-$(resolve_port "$1")}"
      TARGET_USER="''${user:-$(resolve_user "$1")}"
      TARGET_HOST="$TARGET_USER@$TARGET_IP"
    }

    build_ssh_cmd() {
      SSH_CMD=(
        "$SSH"
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o ControlMaster=no
        -o ControlPath=none
        -o LogLevel=VERBOSE
        -p "$TARGET_PORT"
      )
      if $insecure; then
        SSH_CMD+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
      else
        SSH_CMD+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KNOWN_HOSTS")
      fi
      if [[ -n "$jump" ]]; then
        if [[ -n "$jump_key" ]]; then
          local proxy
          printf -v proxy '%q ' "$SSH" -i "$jump_key" -p "''${jump_port:-22}" -W %h:%p "$jump"
          SSH_CMD+=(-o "ProxyCommand=$proxy")
        else
          SSH_CMD+=(-J "$jump''${jump_port:+:$jump_port}")
        fi
      fi
      [[ -z "$key" ]] || SSH_CMD+=(-i "$key")
    }

    check_host() {
      log "$node" "Checking $TARGET_HOST:$TARGET_PORT..."
      "''${SSH_CMD[@]}" "$TARGET_HOST" true 2>/dev/null || {
        log "$node" "ERROR: unreachable or host key does not match"
        return 1
      }
    }

    remote_privileged() {
      if [[ "$TARGET_USER" == root ]]; then
        "''${SSH_CMD[@]}" "$TARGET_HOST" "$@"
      else
        "''${SSH_CMD[@]}" "$TARGET_HOST" sudo "$@"
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
      CLEANUP_TMP="$tmp"
      trap cleanup_tmp EXIT
      ${pkgs.age}/bin/age -d -i ~/.ssh/k3s-admin \
        "secrets/hosts/$node/ssh-key.age" > "$tmp/ssh_host_ed25519_key"
      cp "secrets/hosts/$node/ssh-key.pub" "$tmp/ssh_host_ed25519_key.pub"

      log "$node" "Installing managed SSH host identity for age secrets"
      remote_privileged install -m 0600 /dev/stdin /etc/ssh/.ssh_host_ed25519_key.new \
        < "$tmp/ssh_host_ed25519_key"
      remote_privileged install -m 0644 /dev/stdin /etc/ssh/.ssh_host_ed25519_key.pub.new \
        < "$tmp/ssh_host_ed25519_key.pub"
      remote_privileged mv /etc/ssh/.ssh_host_ed25519_key.new /etc/ssh/ssh_host_ed25519_key
      remote_privileged mv /etc/ssh/.ssh_host_ed25519_key.pub.new /etc/ssh/ssh_host_ed25519_key.pub
      $RM -rf "$tmp"
      CLEANUP_TMP=""
      trap - EXIT
    }

    set_nix_ssh_opts() {
      local option escaped=""
      for option in "''${SSH_CMD[@]:1}"; do
        printf -v option '%q' "$option"
        escaped+=" $option"
      done
      export NIX_SSHOPTS="$escaped"
    }

    nix_user_is_trusted() {
      local trusted groups entry
      trusted=$("''${SSH_CMD[@]}" "$TARGET_HOST" nix show-config 2>/dev/null |
        ${pkgs.gnused}/bin/sed -n 's/^trusted-users = //p')
      groups=$("''${SSH_CMD[@]}" "$TARGET_HOST" id -nG)
      for entry in $trusted; do
        [[ "$entry" == "$TARGET_USER" ]] && return 0
        [[ "$entry" == @* && " $groups " == *" ''${entry#@} "* ]] && return 0
      done
      return 1
    }

    prepare_untrusted_target() {
      SYSTEM_PATH=""
      [[ "$TARGET_USER" != root ]] || return 0
      nix_user_is_trusted && return 0

      local remote_program="/run/cluster-nix-daemon-$$"
      log "$node" "Nix does not trust $TARGET_USER yet; copying through sudo"
      SYSTEM_PATH=$("$NIX" build --no-link --print-out-paths \
        ".#nixosConfigurations.$node.config.system.build.toplevel")

      printf '%s\n' '#!/bin/sh' \
        'exec sudo /run/current-system/sw/bin/nix-store "$@"' |
        remote_privileged install -m 0755 /dev/stdin "$remote_program"
      if ! "$NIX" copy \
        --to "ssh://$TARGET_HOST?remote-program=$remote_program" \
        "$SYSTEM_PATH"; then
        remote_privileged rm -f "$remote_program"
        return 1
      fi
      remote_privileged rm -f "$remote_program"
    }

    rebuild_target() {
      local action="$1"
      local action_args=()
      local sudo_args=()
      local source_args=(--flake ".#$node")
      [[ -z "$action" ]] || action_args+=("$action")
      [[ "$TARGET_USER" == root ]] || sudo_args+=(--sudo)
      set_nix_ssh_opts
      prepare_untrusted_target
      [[ -z "$SYSTEM_PATH" ]] || source_args=(--store-path "$SYSTEM_PATH" --no-reexec)
      if [[ $(resolve_platform "$node") == lxc ]]; then
        "$NIXOS_REBUILD" boot "''${action_args[@]}" "''${source_args[@]}" --target-host "$TARGET_HOST" "''${sudo_args[@]}"
        log "$node" "LXC generation staged; reboot the container from its host to activate it"
      elif [[ -n "$SYSTEM_PATH" ]]; then
        "$NIXOS_REBUILD" boot "''${action_args[@]}" "''${source_args[@]}" --target-host "$TARGET_HOST" "''${sudo_args[@]}"
        log "$node" "Trust-transition generation staged; reboot the VM to activate it"
      else
        "$NIXOS_REBUILD" switch "''${action_args[@]}" "''${source_args[@]}" --target-host "$TARGET_HOST" "''${sudo_args[@]}"
      fi
    }

    check_k3s() {
      "''${SSH_CMD[@]}" "$TARGET_HOST" systemctl is-active --quiet k3s || {
        log "$node" "ERROR: k3s is not active after deployment"
        return 1
      }
    }

    usage() {
      echo "Usage: deploy <command> [args...]"
      echo ""
      echo "Commands:"
      echo "  init     <node> [opts]  Initial deployment (nixos-anywhere)"
      echo "  rebuild  <node> [opts]  Update one node"
      echo "  all      [opts]         Rebuild nodes sequentially; init node is last"
      echo "  rollback <node> [opts]  Roll back one node"
      echo ""
      echo "Options:"
      echo "  -i, --identity <key>       SSH private key"
      echo "  -u, --user <user>          SSH user override"
      echo "  -H, --host <host>          Target override (single-node commands only)"
      echo "  -p, --port <port>          SSH port override"
      echo "  -j, --jump <host>          Jump host"
      echo "  --jump-key <key>           Jump host SSH key"
      echo "  --jump-port <port>         Jump host port"
      echo "  --insecure-bootstrap       Accept an unmanaged initial host key"
      echo ""
      echo "Nodes: ${lib.concatStringsSep ", " nodeNames}"
      echo "Rebuild order: ${lib.concatStringsSep " -> " rebuildOrder}"
    }

    cmd_init() {
      parse_args "$@" || { usage; exit 1; }
      [[ -n "$node" ]] || { usage; exit 1; }
      [[ $(resolve_platform "$node") != lxc ]] || {
        log "$node" "ERROR: LXC nodes must be pre-installed and deployed with 'rebuild'"
        exit 1
      }
      [[ -n "$user" ]] || user=root
      require_key "$key"
      [[ -f ~/.ssh/k3s-admin ]] || { log "$node" "ERROR: ~/.ssh/k3s-admin is required"; exit 1; }
      resolve_target "$node"
      build_ssh_cmd
      check_host

      local tmp
      tmp=$($MKTEMP -d)
      CLEANUP_TMP="$tmp"
      trap cleanup_tmp EXIT
      $INSTALL -d -m 0755 "$tmp/etc/ssh"
      ${pkgs.age}/bin/age -d -i ~/.ssh/k3s-admin "secrets/hosts/$node/ssh-key.age" \
        > "$tmp/etc/ssh/ssh_host_ed25519_key"
      chmod 0600 "$tmp/etc/ssh/ssh_host_ed25519_key"
      cp "secrets/hosts/$node/ssh-key.pub" "$tmp/etc/ssh/ssh_host_ed25519_key.pub"

      local host_key_options
      if $insecure; then
        host_key_options=(--ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null)
      else
        host_key_options=(--ssh-option StrictHostKeyChecking=yes --ssh-option "UserKnownHostsFile=$KNOWN_HOSTS")
      fi
      ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
        "''${host_key_options[@]}" \
        --ssh-option LogLevel=VERBOSE \
        --ssh-option "Port=$TARGET_PORT" \
        ''${key:+--ssh-option "IdentityFile=$key"} \
        --extra-files "$tmp" \
        --flake ".#$node" \
        "$TARGET_HOST"
    }

    cmd_rebuild() {
      parse_args "$@" || { usage; exit 1; }
      [[ -n "$node" ]] || { usage; exit 1; }
      require_key "$key"
      resolve_target "$node"
      build_ssh_cmd
      log rebuild "$node -> $TARGET_HOST:$TARGET_PORT"
      check_host
      bootstrap_lxc_host_key
      rebuild_target ""
      check_k3s
    }

    cmd_all() {
      local key="" jump="" jump_key="" jump_port="" user="" port=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -i|--identity) require_value "$@" || exit 1; key="$2"; shift 2 ;;
          -j|--jump) require_value "$@" || exit 1; jump="$2"; shift 2 ;;
          --jump-key) require_value "$@" || exit 1; jump_key="$2"; shift 2 ;;
          --jump-port) require_value "$@" || exit 1; jump_port="$2"; shift 2 ;;
          -u|--user) require_value "$@" || exit 1; user="$2"; shift 2 ;;
          -p|--port) require_value "$@" || exit 1; port="$2"; shift 2 ;;
          *) echo "Unsupported option for deploy all: $1" >&2; usage; exit 1 ;;
        esac
      done
      require_key "$key"
      local args=()
      [[ -z "$key" ]] || args+=(-i "$key")
      [[ -z "$jump" ]] || args+=(-j "$jump")
      [[ -z "$jump_key" ]] || args+=(--jump-key "$jump_key")
      [[ -z "$jump_port" ]] || args+=(--jump-port "$jump_port")
      [[ -z "$user" ]] || args+=(-u "$user")
      [[ -z "$port" ]] || args+=(-p "$port")
      for target_node in ${lib.concatStringsSep " " rebuildOrder}; do
        cmd_rebuild "$target_node" "''${args[@]}"
      done
    }

    cmd_rollback() {
      parse_args "$@" || { usage; exit 1; }
      [[ -n "$node" ]] || { usage; exit 1; }
      require_key "$key"
      resolve_target "$node"
      build_ssh_cmd
      log rollback "$node -> $TARGET_HOST:$TARGET_PORT"
      check_host
      rebuild_target "--rollback"
      check_k3s
    }

    case "''${1:-}" in
      init) shift; cmd_init "$@" ;;
      rebuild) shift; cmd_rebuild "$@" ;;
      all) shift; cmd_all "$@" ;;
      rollback) shift; cmd_rollback "$@" ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
