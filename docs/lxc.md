# Running a node in a Proxmox LXC container

The container must already run NixOS. The host provides the kernel, so load
the modules k3s needs at boot on the Proxmox host
(`/etc/modules-load.d/k3s.conf`):

```text
overlay
br_netfilter
vxlan
wireguard
iscsi_tcp   # storage nodes only
```

The `k3s-preflight` unit in the container checks for these modules, cgroup v2,
`/dev/kmsg`, a writable `/proc/sys` and, on storage nodes, a mount on `/data`
and an unlimited memlock limit. k3s does not start until they are present.

The profile TeddySMP runs with (`/etc/pve/lxc/100.conf`):

```text
arch: amd64
cores: 5
features: nesting=1,keyctl=1
hostname: teddysmp
memory: 14336
net0: name=ens18,bridge=vmbr1,gw=192.168.2.1,hwaddr=BC:24:11:AD:5D:35,ip=192.168.2.100/24,type=veth
ostype: nixos
rootfs: local:100/vm-100-disk-0.raw,size=164G
swap: 1024
lxc.apparmor.profile: unconfined
lxc.prlimit.memlock: unlimited
lxc.mount.entry: /sys/fs/bpf sys/fs/bpf none bind,create=dir
lxc.cgroup2.devices.allow: c 1:11 rwm
lxc.mount.entry: /dev/kmsg dev/kmsg none bind,create=file
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
lxc.mount.auto: proc:rw sys:rw
lxc.cap.drop:
```

Notes on this profile:

- This profile has no `unprivileged: 1`, keeps every capability
  (`lxc.cap.drop:` is empty) and disables AppArmor, so root inside the
  container is close to root on the host. Use a VM for nodes that run
  untrusted workloads. k3s no longer needs `CAP_SYS_MODULE` once the modules
  above are preloaded, so dropping `sys_module` again is a reasonable first
  hardening step (untested here).
- `net0` names the interface `ens18`, while `clusters/teddysmp/cluster.nix`
  configures `eth0`. One of them is out of date; `interface` must match the
  name inside the container for the static address and the VIP.
- The `/sys/fs/bpf` mount was needed by Cilium and can go.
