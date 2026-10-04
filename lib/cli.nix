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
  # where `secrets` lives in the repository, for the commands that write it
  secretsDir,
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
      ${table "STORAGE" (n: lib.optionalString (lib.elem "storage" n.roles) "yes")}

      die() { echo "error: $*" >&2; exit 1; }

      usage() {
        cat >&2 <<EOF
      usage: $cluster <command>

        install <node> <user@host>   first installation; a VM's disks are ERASED
        switch <node>... | all       deploy; 'all' goes ''${order[*]} one at a time
                                     and waits for each node to be Ready
        remove <node>                move its data and workloads away and delete it
                                     from Kubernetes (and etcd); then drop it from
                                     cluster.nix, secrets sync, switch all
        rollback <node>              activate the previous generation
        ssh <node> [command]
        status                       nodes, and whether every chart is installed;
                                     fails and shows the log if one is failing
        kubeconfig [node]            write ~/.kube/$cluster.yaml, print the tunnel
        image <archive> [node]...    import an image tarball (default: all nodes)
        secrets sync                 create missing keys, re-encrypt everything
        secrets edit <file>          e.g. etcd-s3.age

      Decrypts with \$AGE_IDENTITY (default ~/.ssh/k3s-admin).
      EOF
        exit 1
      }

      identity=''${AGE_IDENTITY:-$HOME/.ssh/k3s-admin}

      # Only install, switch, rollback and secrets need the repository.
      repo() {
        root=$(git rev-parse --show-toplevel 2>/dev/null) || die "run this inside the cluster repository"
        dir=$root/${secretsDir}
      }
      umask 077
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      check_node() {
        local node=''${1:-}
        [[ -n $node && -v "HOST[$node]" ]] || die "unknown node '$node' (nodes: ''${order[*]})"
      }

      ssh_opts() {
        SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts" -p "''${PORT[$1]}")
      }

      remote() {
        local node=$1
        shift
        ssh_opts "$node"
        # shellcheck disable=SC2029 # arguments are a remote command line by design
        ssh "''${SSH_OPTS[@]}" "admin@''${HOST[$node]}" "$@"
      }

      kube() {
        local server=$1
        shift
        remote "$server" "sudo k3s kubectl $(printf '%q ' "$@")"
      }

      # First server other than $1 that is reachable and runs k3s.
      live_server() {
        local n
        for n in "''${order[@]}"; do
          if [[ $n != "''${1:-}" && ''${ROLE[$n]} == server ]] && remote "$n" systemctl is-active --quiet k3s 2>/dev/null; then
            echo "$n"
            return
          fi
        done
        return 1
      }

      rebuild() {
        local action=$1 node=$2
        shift 2
        ssh_opts "$node"
        NIX_SSHOPTS="''${SSH_OPTS[*]}" nixos-rebuild "$action" --flake "$root#$cluster-$node" \
          --target-host "admin@''${HOST[$node]}" --sudo "$@"
      }

      # Restart a node and wait until it is back; used for LXC containers,
      # whose new generation only becomes active on a fresh boot.
      restart() {
        local node=$1 before now i
        # start time of PID 1: a container restart does not change the host's boot id
        before=$(remote "$node" cut -d' ' -f22 /proc/1/stat)
        echo "$node: restarting"
        remote "$node" sudo systemctl reboot || true
        for ((i = 0; i < 60; i++)); do
          sleep 5
          now=$(remote "$node" cut -d' ' -f22 /proc/1/stat 2>/dev/null) || continue
          [[ $now == "$before" ]] || return 0
        done
        die "$node: not back after 5 minutes"
      }

      activate() {
        local node=$1 probe=$1
        shift
        if [[ ''${PLATFORM[$node]} == lxc ]]; then
          rebuild boot "$node" "$@"
          restart "$node"
        else
          rebuild switch "$node" "$@"
        fi
        if [[ ''${ROLE[$node]} != server ]]; then
          probe=$(live_server) || die "no server with k3s running"
        fi
        remote "$node" "timeout 180 sh -c 'until systemctl is-active --quiet k3s; do sleep 2; done'" ||
          die "$node: k3s is not running; see: $cluster ssh $node journalctl -b -u k3s-preflight -u k3s"
        kube "$probe" wait --for=condition=Ready "node/$node" --timeout=5m >/dev/null ||
          die "$node: not Ready after 5 minutes; stopping here"
        echo "$node: Ready"
      }

      cmd_install() {
        local node=''${1:-} target=''${2:-} answer server
        check_node "$node"
        [[ -n $target ]] || usage
        repo
        if [[ $node == "$init" ]] && server=$(live_server "$node"); then
          die "$server already runs this cluster, and $node as \`init\` would start a new one. Set \`init\` to $server in cluster.nix first."
        fi
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
          ssh "''${insecure[@]}" "$target" sudo systemctl reboot || true
          echo "$node: installed and restarting; check it with: $cluster ssh $node"
        fi
      }

      cmd_remove() {
        local node=''${1:-} server left
        check_node "$node"
        server=$(live_server "$node") || die "no other server with k3s running"
        if remote "$node" true 2>/dev/null; then
          echo "$node: cordoning (through $server)"
          kube "$server" cordon "$node"
          if [[ -n ''${STORAGE[$node]} ]]; then
            kube "$server" -n longhorn-system patch "nodes.longhorn.io/$node" --type merge \
              -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
            while :; do
              left=$(kube "$server" -n longhorn-system get replicas.longhorn.io \
                -o "jsonpath={.items[?(@.spec.nodeID==\"$node\")].metadata.name}") || die "cannot list Longhorn replicas"
              [[ -n $left ]] || break
              echo "$node: Longhorn is moving $(wc -w <<<"$left") replica(s); volumes with as many replicas as storage nodes cannot move"
              sleep 30
            done
          fi
          kube "$server" drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=15m
          # /etc is read-only on NixOS: stop k3s until the next boot
          remote "$node" sudo systemctl mask --runtime --now k3s
        else
          echo "$node: unreachable; removing it without draining"
        fi
        kube "$server" delete node "$node"
        if [[ -n ''${STORAGE[$node]} ]]; then
          kube "$server" -n longhorn-system delete "nodes.longhorn.io/$node" --ignore-not-found ||
            echo "$node: remove it in the Longhorn UI once Longhorn shows it as down"
        fi
        echo "$node: removed from Kubernetes. Now delete it from clusters/$cluster/cluster.nix, then run 'secrets sync' and 'switch all'."
        echo "$node: k3s stays stopped until it reboots; power it off or reinstall it before then, or it rejoins while the other nodes still list it."
        if [[ $node == "$init" ]]; then
          echo "$node is \`init\`: set init to another server, e.g. $server"
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
        for node in "$dir"/hosts/*/; do
          node=$(basename "$node")
          if [[ -d $dir/hosts/$node && ! -v "HOST[$node]" ]]; then
            rm -rf "''${dir:?}/hosts/$node"
            echo "$node: no longer in cluster.nix; deleted its keys"
          fi
        done
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
        local node=''${1:-} out=$HOME/.kube/$cluster.yaml
        if [[ -z $node ]]; then node=$(live_server) || die "no server with k3s running"; fi
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

      # Charts are installed by the helm-controller after a switch has
      # finished: its Job helm-install-<chart> holds the outcome.
      cmd_status() {
        local server chart charts jobs job ok failed state bad=0
        server=$(live_server) || die "no server with k3s running"
        kube "$server" get nodes -o wide
        echo
        jobs=$(kube "$server" -n kube-system get jobs --no-headers \
          -o custom-columns=NAME:.metadata.name,OK:.status.succeeded,FAILED:.status.failed)
        charts=$(kube "$server" -n kube-system get helmcharts -o 'jsonpath={.items[*].metadata.name}')
        declare -A OK FAILED
        while read -r job ok failed; do
          [[ -n $job ]] || continue
          OK[$job]=$ok
          FAILED[$job]=$failed
        done <<<"$jobs"
        for chart in $charts; do
          job=helm-install-$chart
          if [[ ! -v "OK[$job]" ]]; then
            state=waiting
          elif [[ ''${OK[$job]} != "<none>" ]]; then
            state=installed
          elif [[ ''${FAILED[$job]} != "<none>" ]]; then
            state=failing
          else
            state=installing
          fi
          printf '%-24s %s\n' "$chart" "$state"
          if [[ $state == failing ]]; then
            bad=1
            kube "$server" -n kube-system logs "job/$job" --tail=20 | sed 's/^/    /' || true
          fi
        done
        return "$bad"
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
        remove) cmd_remove "$@" ;;
        switch | rollback)
          repo
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
        status) cmd_status ;;
        image) cmd_image "$@" ;;
        secrets)
          repo
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
