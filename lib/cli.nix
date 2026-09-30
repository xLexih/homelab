# `nix run .#<cluster> -- <command>`: install, deploy and operate one cluster.
{
  lib,
  writeShellApplication,
  writeText,
  age,
  coreutils,
  git,
  gnused,
  gnutar,
  gzip,
  nixos-anywhere,
  nixos-rebuild,
  openssh,
  wireguard-tools,
  cluster,
  secrets,
}: let
  inherit (cluster) name;
  nodes = lib.attrValues cluster.nodes;
  isServer = n: lib.elem "server" n.roles;
  others = lib.filter (n: n.name != cluster.init) nodes;
  # init first, then the other servers, then agents
  order = [cluster.init] ++ map (n: n.name) (lib.filter isServer others ++ lib.filter (n: !isServer n) others);

  knownHosts = writeText "${name}-known-hosts" (lib.concatMapStrings (n: let
    file = secrets + "/hosts/${n.name}/ssh-key.pub";
    key = lib.removeSuffix "\n" (builtins.readFile file);
    entry = host:
      if n.sshPort == 22
      then host
      else "[${host}]:${toString n.sshPort}";
  in
    lib.optionalString (builtins.pathExists file) (lib.concatMapStrings (host: "${entry host} ${key}\n")
      (lib.unique (lib.filter (h: h != null) [n.sshHost n.ip n.wgIP]))))
  nodes);

  table = var: f: "declare -A ${var}=(${lib.concatMapStringsSep " " (n: "[${n.name}]=${lib.escapeShellArg (f n)}") nodes})";
in
  writeShellApplication {
    inherit name;
    runtimeInputs = [age coreutils git gnused gnutar gzip nixos-anywhere nixos-rebuild openssh wireguard-tools];
    text = ''
      cluster=${name}
      init=${cluster.init}
      order=(${lib.concatStringsSep " " order})
      known_hosts=${knownHosts}
      ${table "HOST" (n: n.sshHost)}
      ${table "PORT" (n: toString n.sshPort)}
      ${table "PLATFORM" (n: n.platform)}
      ${table "ROLE" (n:
        if isServer n
        then "server"
        else "agent")}
      ${table "WGIP" (n: n.wgIP)}

      die() { echo "error: $*" >&2; exit 1; }

      usage() {
        cat >&2 <<EOF
      usage: $cluster <command>

        install <node> <user@host>   first installation; a VM's disks are ERASED
        switch <node>... | all       deploy; 'all' goes ''${order[*]} one at a time
                                     and waits for each node to be Ready
        rollback <node>              activate the previous generation
        ssh <node> [command]
        kubeconfig [node]            write ~/.kube/$cluster.yaml, print the tunnel
        image <archive> [node]...    import an image tarball (default: all nodes)
        secrets sync                 create missing keys, re-encrypt everything
        secrets edit <file>          e.g. etcd-s3.age

      Decrypts with \$AGE_IDENTITY (default ~/.ssh/k3s-admin).
      EOF
        exit 1
      }

      root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run this inside the cluster repository"
      dir=$root/clusters/$cluster/secrets
      identity=''${AGE_IDENTITY:-$HOME/.ssh/k3s-admin}
      umask 077
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      check_node() {
        local node=''${1:-}
        [[ -n $node && -v "HOST[$node]" ]] || die "unknown node '$node' (nodes: ''${order[*]})"
      }

      ssh_opts() {
        SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -p "''${PORT[$1]}")
      }

      remote() {
        local node=$1
        shift
        ssh_opts "$node"
        # shellcheck disable=SC2029 # arguments are a remote command line by design
        ssh "''${SSH_OPTS[@]}" "admin@''${HOST[$node]}" "$@"
      }

      rebuild() {
        local action=$1 node=$2
        shift 2
        ssh_opts "$node"
        NIX_SSHOPTS="''${SSH_OPTS[*]}" nixos-rebuild "$action" --flake "$root#$cluster-$node" \
          --target-host "admin@''${HOST[$node]}" --sudo "$@"
      }

      activate() {
        local node=$1 probe=$1
        shift
        if [[ ''${PLATFORM[$node]} == lxc ]]; then
          rebuild boot "$node" "$@"
          echo "$node: generation staged; restart the container from Proxmox to activate it"
          return
        fi
        rebuild switch "$node" "$@"
        [[ ''${ROLE[$node]} == server ]] || probe=$init
        remote "$node" systemctl is-active --quiet k3s || die "$node: k3s is not running"
        remote "$probe" sudo k3s kubectl wait --for=condition=Ready "node/$node" --timeout=5m >/dev/null ||
          die "$node: not Ready after 5 minutes; stopping here"
        echo "$node: Ready"
      }

      cmd_install() {
        local node=''${1:-} target=''${2:-} answer
        check_node "$node"
        [[ -n $target ]] || usage
        mkdir -p "$tmp/etc/ssh"
        age -d -i "$identity" "$dir/hosts/$node/ssh-key.age" >"$tmp/etc/ssh/ssh_host_ed25519_key"
        cp "$dir/hosts/$node/ssh-key.pub" "$tmp/etc/ssh/ssh_host_ed25519_key.pub"
        if [[ ''${PLATFORM[$node]} == vm ]]; then
          read -rp "This ERASES every disk of $node at $target. Type '$node' to continue: " answer
          [[ $answer == "$node" ]] || die "aborted"
          nixos-anywhere --extra-files "$tmp" --flake "$root#$cluster-$node" "$target"
        else
          local insecure=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
          tar -C "$tmp" -c etc/ssh | ssh "''${insecure[@]}" "$target" sudo tar -C / --no-same-owner -x
          NIX_SSHOPTS="''${insecure[*]}" nixos-rebuild boot --flake "$root#$cluster-$node" --target-host "$target" --sudo
          echo "$node: installed; restart the container from Proxmox to activate it"
        fi
      }

      recipients() {
        RCPT=(-R "$dir/admin.pub")
        local node
        case $1 in
          k3s-token.age | etcd-s3.age)
            for node in "''${order[@]}"; do
              if [[ $1 == k3s-token.age || ''${ROLE[$node]} == server ]]; then
                RCPT+=(-R "$dir/hosts/$node/ssh-key.pub")
              fi
            done
            ;;
          hosts/*/wireguard.age)
            node=''${1#hosts/}
            RCPT+=(-R "$dir/hosts/''${node%%/*}/ssh-key.pub")
            ;;
          hosts/*/ssh-key.age) ;;
          *) die "unknown secret '$1' (k3s-token.age, etcd-s3.age, hosts/<node>/{ssh-key,wireguard}.age)" ;;
        esac
      }

      encrypt() {
        recipients "$1"
        age "''${RCPT[@]}" -o "$dir/$1.tmp"
        mv "$dir/$1.tmp" "$dir/$1"
      }

      decrypt() {
        age -d -i "$identity" "$dir/$1"
      }

      cmd_sync() {
        local node file
        for node in "''${order[@]}"; do
          mkdir -p "$dir/hosts/$node"
          if [[ ! -f $dir/hosts/$node/ssh-key.age ]]; then
            ssh-keygen -q -t ed25519 -N "" -C "$node" -f "$tmp/key"
            mv "$tmp/key.pub" "$dir/hosts/$node/ssh-key.pub"
            encrypt "hosts/$node/ssh-key.age" <"$tmp/key"
            rm "$tmp/key"
            echo "$node: generated SSH host key"
          fi
          if [[ ! -f $dir/hosts/$node/wireguard.age ]]; then
            wg genkey >"$tmp/wg"
            wg pubkey <"$tmp/wg" >"$dir/hosts/$node/wireguard.pub"
            encrypt "hosts/$node/wireguard.age" <"$tmp/wg"
            rm "$tmp/wg"
            echo "$node: generated WireGuard key"
          fi
        done
        if [[ ! -f $dir/k3s-token.age ]]; then
          od -An -tx1 -N32 /dev/urandom | tr -d ' \n' | encrypt k3s-token.age
          echo "generated k3s token"
        fi
        for file in "$dir"/k3s-token.age "$dir"/etcd-s3.age "$dir"/hosts/*/*.age; do
          [[ -f $file ]] || continue
          file=''${file#"$dir"/}
          decrypt "$file" >"$tmp/plain"
          encrypt "$file" <"$tmp/plain"
        done
        git -C "$root" add "$dir"
        echo "secrets of $cluster re-encrypted for the current nodes and staged in git"
      }

      cmd_edit() {
        local file=''${1:-}
        recipients "$file"
        [[ ! -f $dir/$file ]] || decrypt "$file" >"$tmp/plain"
        "''${EDITOR:-vi}" "$tmp/plain"
        [[ -s $tmp/plain ]] || die "empty file; nothing written"
        encrypt "$file" <"$tmp/plain"
        git -C "$root" add "$dir/$file"
      }

      cmd_kubeconfig() {
        local node=''${1:-$init} out=$HOME/.kube/$cluster.yaml
        check_node "$node"
        [[ ''${ROLE[$node]} == server ]] || die "$node is not a server"
        mkdir -p "$HOME/.kube"
        remote "$node" sudo cat /etc/rancher/k3s/k3s.yaml |
          sed -E "s#server: https://[^:]+:6443#server: https://127.0.0.1:6443#; s#^( *(name|cluster|user|current-context):) default\$#\1 $cluster#" |
          install -m 0600 /dev/stdin "$out"
        ssh_opts "$node"
        echo "wrote $out; open the API tunnel with:"
        printf '  ssh -N -L 6443:%s:6443' "''${WGIP[$node]}"
        printf ' %q' "''${SSH_OPTS[@]}" "admin@''${HOST[$node]}"
        echo
      }

      cmd_image() {
        local file=''${1:-} node
        [[ -f $file ]] || usage
        shift
        (($#)) || set -- "''${order[@]}"
        for node in "$@"; do
          check_node "$node"
          echo "$node: importing $file"
          gzip -dcf "$file" | remote "$node" sudo k3s ctr images import -
        done
      }

      command=''${1:-}
      shift || true
      case $command in
        install) cmd_install "$@" ;;
        switch | rollback)
          if [[ $command == switch && ''${1:-} == all ]]; then set -- "''${order[@]}"; fi
          (($#)) || usage
          for node in "$@"; do check_node "$node"; done
          extra=()
          if [[ $command == rollback ]]; then extra=(--rollback); fi
          for node in "$@"; do activate "$node" "''${extra[@]}"; done
          ;;
        ssh)
          check_node "''${1:-}"
          node=$1
          shift
          remote "$node" "$@"
          ;;
        kubeconfig) cmd_kubeconfig "$@" ;;
        image) cmd_image "$@" ;;
        secrets)
          [[ -f $dir/admin.pub ]] || die "put your SSH public key(s) in $dir/admin.pub first"
          case ''${1:-} in
            sync) cmd_sync ;;
            edit) cmd_edit "''${2:-}" ;;
            *) usage ;;
          esac
          ;;
        *) usage ;;
      esac
    '';
  }
