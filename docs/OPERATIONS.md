# Operating home

All commands run through `nix run .#home -- <command>`.

## Command reference

| command | what it does |
| --- | --- |
| `install <node> <user@host>` | first installation; a VM's disks are erased |
| `switch <node>... \| all` | deploy, one node at a time, waiting for each to be `Ready` |
| `rollback <node>` | activate the previous generation |
| `remove <node>` | move data and workloads away, delete the node from Kubernetes and etcd |
| `status` | nodes and chart installs; fails if a chart is failing |
| `ssh <node> [command]` | SSH with the pinned host key |
| `kubeconfig [node]` | write `~/.kube/home.yaml` and print the tunnel command |
| `image <archive> [node]...` | import an image tarball (default: every node) |
| `secrets sync` | create keys for new nodes, re-encrypt everything for the current ones |
| `secrets edit <file>` | edit an encrypted file |

`switch all` goes through the init server, the other servers and then the
agents, and stops at the first node that isn't `Ready` within five minutes.

Secrets are decrypted with `$AGE_IDENTITY`, which defaults to
`~/.ssh/k3s-admin`, and `admin.pub` may list several keys. `install`,
`switch`, `rollback` and `secrets` have to run inside this repository.
`secrets sync` stages the files it generates with `git add`, because the flake
only sees tracked files.

## Installing from scratch

The keys and secrets already exist in `clusters/home/secrets`, so a fresh
install only needs the admin key in `ssh-agent` and a NixOS installer booted
on each machine:

```bash
nix flake check

# master1 (init) first, then the rest; a VM's disks are erased after you confirm
nix run .#home -- install master1 root@<installer-ip>
nix run .#home -- install master2 root@<installer-ip>
nix run .#home -- install master3 root@<installer-ip>
```

To bring back the old state, copy an etcd snapshot onto master1 and restore
it as in [DISASTER-RECOVERY.md](DISASTER-RECOVERY.md#etcd-lost-quorum).

`install` boots a VM from any NixOS installer into its final system with
`nixos-anywhere`, putting the node's SSH host key in place first so it can
decrypt its secrets on the first boot. For an LXC node it copies the host key
into the running container, stages the new system and restarts the container.

## Adding and removing nodes

Nodes can be added with any role at any time. A new node joins through the
`init` server, or, if that one isn't answering, through the other servers in
alphabetical order, so `init` doesn't need to be up. It stays `NotReady` until
`switch all` has reached the others, since they don't know its WireGuard key
before then; k3s keeps retrying in the meantime. Existing nodes aren't
restarted: the new peer costs one extra unit on each, and the helm-controller
updates the Cilium, Longhorn and CoreDNS settings that depend on the node list.

`remove` waits for Longhorn to rebuild the node's replicas elsewhere. That
can't happen while a volume has as many replicas as there are storage nodes,
so add a storage node first or lower that volume's replica count. A node
that's already dead is deleted without draining, and deleting a server also
removes its etcd member. On a live node, `remove` stops k3s only until the
next boot, because `/etc` is read-only under NixOS. Power it off or reinstall
it before it reboots, or it will rejoin while the others still list it as a
WireGuard peer. Once `switch all` has run, it can no longer reach them.

Server counts must stay odd. To grow from 1 to 3 or from 3 to 5, add both new
servers to the file and install them in any order; they join through the
existing ones. The `storage` and `gpu` roles can be switched on and off in
place. Turning an agent into a server, or back, means removing the node and
adding it again.

## Debugging on a node

`nix run .#home -- ssh <node>` gives you a shell as `admin` with passwordless
sudo. Every node carries a set of tools for poking around:

- processes: `htop`, `btop`, `iotop`, `lsof`, `strace`, `iostat`/`sar` (sysstat)
- network: `dig`, `tcpdump`, `mtr`, `iperf3`, `ethtool`, `conntrack`, `nmap`,
  `socat`, `curl`, `wg`
- disks and hardware: `ncdu`, `smartctl`, `lspci`, `lsusb`
- everything else: `jq`, `yq`, `tree`, `file`, `vim`, `tmux`, `git`

Anything else in nixpkgs is one comma away: `, rg pattern` runs ripgrep without
installing it. When several packages provide a command, comma asks which one,
which only works in an interactive shell; elsewhere name the package with
`nix shell nixpkgs#ripgrep -c rg pattern`. In an interactive shell, typing a
command that isn't installed lists the packages that have it. Flakes are
enabled, and `nixpkgs` is the exact nixpkgs the node was built from, so
whatever comma fetches matches the system.

Kubernetes itself: on servers, `kubectl` works without sudo (`KUBECONFIG`
points at k3s' admin kubeconfig, readable by `wheel`), e.g. for Cilium
`kubectl -n kube-system exec ds/cilium -- cilium-dbg status`. Agents have no
admin kubeconfig; use a server or `kubeconfig` from your machine.

## Backups

Every server keeps etcd snapshots in `/var/lib/rancher/k3s/server/db/snapshots`,
taken twice a day with the last 14 kept. For an off-site copy, set
`etcdS3 = { endpoint = "…"; bucket = "…"; };` and store the credentials with
`secrets edit etcd-s3.age`:

```text
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
```

Restoring follows the k3s documentation (`k3s server --cluster-reset
--cluster-reset-restore-path=…` on the init server). Longhorn volumes need a
backup target of their own, configured in Longhorn.

## Checks

```bash
nix fmt
nix flake check                                  # everything below; the VM test takes about 10 minutes
nix build .#checks.x86_64-linux.vm -L            # only the VM test, with its log
```

`flake check` evaluates every node, runs alejandra, deadnix and statix,
ShellChecks the cluster command, makes sure a set of broken cluster
definitions is rejected, and fetches every Helm chart against its pinned hash
(`charts`). It also boots the VM test in `tests/`: four nodes
built from the real modules, plus a deployer VM that runs the cluster command
and doubles as a BGP router. The test covers:

- a node joining while the `init` server is down;
- `ssh`, `kubeconfig`, `status`, `image` and `remove`, including removing a
  dead server's etcd member;
- a LoadBalancer address being assigned, announced over ARP and BGP, and
  reaching pods on two nodes with the client's own address;
- pods on different nodes seeing each other's addresses, and NodePorts
  staying closed on the LAN;
- `default-deny` blocking traffic until an app's own policy allows it.

It needs KVM and about 6 GB of free memory. `install`, `switch` and
`rollback` aren't covered, because they need a real installer and network
access.

CI (`.github/workflows/check.yml`) runs everything except the VM test on
pushes to `main` and on pull requests that touch more than documentation:
`nix flake check --no-build` evaluates every node, then the lint, validation,
command and chart checks are built. That takes a minute or two. The VM test runs
only when you start the workflow by hand (Actions, Check, Run workflow, tick
"Also run the VM test"); do that, or run it locally, before deploying network
or k3s changes.

## Upgrading

Updates are deliberate. Run `nix flake update`, then `nix flake check`, then
`switch all`. k3s patch releases come with the lock update; the Kubernetes
minor version only moves when you raise `k3sVersion` in a cluster's
`cluster.nix`, one minor at a time, and `switch all` upgrades the servers
before the agents as k3s requires.

Chart versions and hashes are pinned in `modules/cilium.nix`, `k3s.nix`,
`storage.nix` and `gpu.nix`. Move Longhorn and Cilium one minor version at a
time. The VM test has no internet access, so when a chart's image changes,
update the matching image digest in `tests/default.nix` too
(`nix run nixpkgs#nix-prefetch-docker -- --image-name … --image-tag …`).

<div align="right">

Generated by Opus 5.5

</div>
