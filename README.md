<div align="center">

# NixOS Octelium Homelab Cluster

**Declarative NixOS Kubernetes cluster with Octelium-first access**

[![NixOS](https://img.shields.io/badge/NixOS-26.05-3b5487?logo=NixOS)](https://nixos.org)
[![K3s](https://img.shields.io/badge/K3s-v1.34.5-ffc61c?logo=k3s)](https://k3s.io)
[![WireGuard](https://img.shields.io/badge/WireGuard-v1.0.20250521-88171a?logo=wireguard)](https://wireguard.com)
[![Cilium](https://img.shields.io/badge/Cilium-1.19.3-111827?logo=cilium)](https://cilium.io)
[![kube‑vip](https://img.shields.io/badge/kube--vip-0.9.8-ea5903?logo=octopus-deploy&logoColor=e60012)](https://kube-vip.io)
[![Longhorn](https://img.shields.io/badge/Longhorn-v1.11.1-431439?label=%F0%9F%90%AE%20Longhorn)](https://longhorn.io)

</div>

---

## Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Repository Structure](#repository-structure)

---

## Requirements

- Nix with flakes enabled
- Proxmox VMs, or pre-installed NixOS LXC containers
- SSH access to targets

**Proxmox:** Enable QEMU Guest Agent:

```bash
qm set <vmid> --agent 1        # Options -> QEMU Guest Agent
qm set <vmid> --serial0 socket # Hardware -> Serial port
```

### LXC nodes

LXC nodes support all role combinations: control-plane (`master`), workload
(`worker`), Longhorn (`storage`), and NVIDIA GPU. Set `platform = "lxc"` and
leave `storage.disks` empty because Proxmox owns the root filesystem, mounts,
kernel, modules, and devices. An LXC node may also be the cluster `init` master.

LXC systems are rebuilt in place. `deploy init` intentionally rejects them
because `nixos-anywhere` and disko target bootable machines; bootstrap a
pre-installed NixOS container with `deploy rebuild`.

The Proxmox host must provide the container with:

- a unique hostname and working cgroup v2 delegation;
- a privileged container with `nesting=1` and `keyctl=1` for K3s containerd,
  mount propagation, and privileged Cilium/Longhorn pods;
- a kernel with WireGuard, eBPF, cgroup BPF, and Geneve support;
- a usable bpffs mount at `/sys/fs/bpf`;
- UDP `51820` reachability for the cluster WireGuard mesh.

The LXC profile skips EFI boot, disko, guest agents, host kernel selection,
kernel module loading, KSM, and swap creation. Privileged LXC nodes use K3s's
default overlayfs snapshotter, with the overlay module supplied by Proxmox. See
the upstream
[K3s requirements](https://docs.k3s.io/installation/requirements) and
[Cilium system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/).

Role-specific host preparation:

- `master`: no extra mount is required. For durable etcd storage, optionally
  bind-mount host storage over `/var/lib/rancher/k3s/server/db`.
- `storage`: bind-mount a dedicated ext4/XFS host path at `/data`. K3s will
  refuse to start if `/data` is not a mount point. The host kernel must load
  `iscsi_tcp`; the container enables `iscsid` and exposes `iscsiadm`.
- NVIDIA GPU: install the NVIDIA driver on the Proxmox host, pass
  `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, and
  `/dev/nvidia-uvm-tools` plus matching driver userspace libraries into the
  container. K3s refuses to start when the two mandatory device nodes are
  absent. The configuration installs the runtime and deploys the device plugin
  from the init master, even when the GPU is on another node.

Example Proxmox preparation for container `<ctid>`:

```bash
pct set <ctid> --features nesting=1,keyctl=1
# storage-role nodes only:
pct set <ctid> --mp0 /host/longhorn/<ctid>,mp=/data
```

For Kubernetes networking, load the host modules and add the bpffs/TUN mounts
to `/etc/pve/lxc/<ctid>.conf`, then restart the container:

```bash
modprobe tun wireguard geneve overlay br_netfilter nf_conntrack iscsi_tcp
printf '%s\n' tun wireguard geneve overlay br_netfilter nf_conntrack iscsi_tcp \
  >/etc/modules-load.d/k3s-lxc.conf
sysctl -w net.netfilter.nf_conntrack_max=1048576
```

```text
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.mount.auto: proc:rw sys:rw
lxc.prlimit.memlock: unlimited
lxc.mount.entry: /sys/fs/bpf sys/fs/bpf none bind,create=dir
lxc.cgroup2.devices.allow: c 1:11 rwm
lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

The LXC profile avoids NixOS's recursive read-only `/nix/store` bind mount,
which otherwise loses Proxmox's UID mapping in unprivileged containers. The
K3s preflight checks cgroup v2, the capability set required by Cilium, writable
kernel tunables, bpffs, and the host-provided `/dev/kmsg` character device, and
checks for unlimited inherited memlock when Longhorn is enabled.

GPU device major numbers and driver-library locations vary by driver release,
so add those bind mounts to `/etc/pve/lxc/<ctid>.conf` after checking the host
with `stat /dev/nvidia*` and `ldconfig -p | grep nvidia`.

Example all-role node:

```nix
nodes.lxc1 = {
  platform = "lxc";
  roles = ["master" "worker" "storage"];
  location = "home";
  network = {
    wgIP = "10.100.0.12";
    lanIP = "192.168.2.112";
    gateway = "192.168.2.1";
    endpoint = "lxc1.example.com";
    sshUser = "root";
  };
  podCIDR = "10.42.12.0/24";
  gpu = {
    enable = true;
    vendor = "nvidia";
  };
  storage.disks = [];
};
```

Deploy a pre-installed LXC node:

```bash
nix run .#secrets -- init
nix run .#secrets -- rekey
nix run .#deploy -- rebuild <node> -i <current-key> -H <current-ip> -u root
```

The first LXC rebuild installs the repository-managed SSH host identity before
activation so age-encrypted node secrets can be decrypted. The current login
key is used for that bootstrap. LXC rebuilds stage a boot generation rather
than switching live because replacing D-Bus inside a running container can
disconnect NixOS activation. Reboot the container from Proxmox afterward; then
use `~/.ssh/k3s-admin`.

### WireGuard

Peers in the same location use their LAN addresses. Each cluster forms its
own WireGuard mesh. Nodes in different clusters are independent and do not
peer with each other, keeping cluster boundaries clean.

The home cluster uses LAN addresses only (no public endpoints needed).

## Quick Start

```bash
# Clusters are defined in config/<name>.nix.
# Each cluster has scoped packages: deploy-<name>, secrets-<name>, config-<name>.

# 1. Generate admin SSH key (same key used for all clusters)
ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin -N ""
cp ~/.ssh/k3s-admin.pub secrets/admin.pub

# 2. Generate cluster secrets
nix run .#secrets-home -- init
git add -A && git commit -m "secrets"

# 3. Deploy the home cluster init node
nix run .#deploy-home -- init master1 -i ~/.ssh/k3s-admin

# 4. Join remaining home nodes
nix run .#deploy-home -- rebuild master2 -i ~/.ssh/k3s-admin
nix run .#deploy-home -- rebuild master3 -i ~/.ssh/k3s-admin

# 5. Fetch kubeconfig
nix run .#config-home -- master1 ~/.ssh/k3s-admin
```

## Commands

| Command                                                       | Description                                    |
| ------------------------------------------------------------- | ---------------------------------------------- |
| `nix run .#secrets-home -- init`                              | Generate home cluster secrets                  |
| `nix run .#secrets-teddysmp -- init`                          | Generate teddysmp cluster secrets              |
| `nix run .#deploy-home -- rebuild <node> [key]`               | Rebuild a home cluster node                    |
| `nix run .#deploy-teddysmp -- rebuild <node> [key]`           | Rebuild a teddysmp cluster node                |
| `nix run .#deploy-home -- all [key] [--parallel]`             | Rebuild all home nodes                         |
| `nix run .#deploy-home -- rollback <node> [key]`              | Rollback home node                             |
| `nix run .#config-home -- <node> [key]`                       | Fetch home kubeconfig                          |
| `nix run .#config-teddysmp -- <node> [key]`                   | Fetch teddysmp kubeconfig                      |

## Repository Structure

```
.
├── flake.nix                  # Entry point
├── config/
│   ├── home.nix               # Home cluster (3 masters)
│   ├── teddysmp.nix           # TeddySMP cluster (single node)
│   └── example.nix            # Full example with all options
├── apps/
│   ├── octelium/              # Octelium install scaffold
│   ├── template/              # App manifest template
│   ├── devspace-test/         # DevSpace example
│   └── mirrord-test/          # mirrord example
├── modules/
│   ├── base/                  # SSH, users, bootloader, kernel tuning
│   ├── network/               # WireGuard, firewall, HAProxy
│   ├── hardware/              # Disk partitioning, GPU
│   ├── kubernetes/            # K3s, etcd, Helm, CoreDNS
│   ├── cni/                   # Cilium
│   ├── storage/               # Longhorn
│   ├── loadbalancer/          # kube‑vip
│   └── registry/              # Docker registry
├── lib/
│   ├── mkCluster.nix          # Multi-cluster factory function
│   └── helpers.nix            # Validation & helper functions
├── scripts/                   # deploy, secrets, image, get‑kubeconfig
└── secrets/                   # Age‑encrypted secrets (generated by `nix run .#secrets`)
```

## Direction

Each location gets its own Kubernetes cluster, scoped via `config/<name>.nix`.
Octelium is deployed per-cluster as the primary access layer. The core stays
NixOS-based, SSH/bastion deployable, and simple enough to operate without
app-specific legacy routing.
