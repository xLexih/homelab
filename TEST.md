 ## 1. Prepare the Sylant Proxmox host

  Run on the Proxmox host, replacing <ctid>:

  mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf

  modprobe wireguard geneve iscsi_tcp
  printf '%s\n' wireguard geneve iscsi_tcp \
    >/etc/modules-load.d/k3s-lxc.conf

  pct set <ctid> --features nesting=1,keyctl=1

  Add these lines to /etc/pve/lxc/<ctid>.conf:

  lxc.apparmor.profile: unconfined
  lxc.mount.entry: /sys/fs/bpf sys/fs/bpf none bind,create=dir
  lxc.cgroup2.devices.allow: c 10:200 rwm
  lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file

  Restart the container:

  pct reboot <ctid>

  ## 2. Configure UDP forwarding

  Home router:

  flowernode.com:51821/UDP → 192.168.2.105:51820  # master1
  flowernode.com:51822/UDP → 192.168.2.106:51820  # master2
  flowernode.com:51823/UDP → 192.168.2.107:51820  # master3

  Sylant router/Proxmox:

  teddysmp.com:51820/UDP → 192.168.2.100:51820

  ## 3. Rebuild the existing masters

  From /data/project/homelab/cluster:

  for node in master1 master2 master3; do
    nix run .#deploy -- rebuild "$node" -i ~/.ssh/k3s-admin
  done

  ## 4. Bootstrap and rebuild teddysmp

  Ensure ~/.ssh/k3s-admin exists; it decrypts the generated managed host identity.

  nix run .#deploy -- rebuild teddysmp \
    -i ~/.ssh/sylant_ed25519 \
    -H 83.147.217.249 \
    -u root

  This first rebuild replaces the temporary LXC SSH host identity and authorized login key. Afterwards, use ~/.ssh/k3s-admin.

  ## 5. Verify

  ssh -i ~/.ssh/k3s-admin root@teddysmp.com \
    'hostname; systemctl is-active wireguard-wg0 k3s; wg show'

  From master1:

  ssh -i ~/.ssh/k3s-admin root@192.168.2.105 \
    'k3s kubectl get nodes -o wide'

  teddysmp should appear Ready, with zone sylant.

  Future full-cluster rebuilds:

  nix run .#deploy -- all -i ~/.ssh/k3s-admin

  The full teddysmp closure, deployment helper, generated SSH targets, WireGuard endpoints, and flake checks all pass. No remote configuration was changed during inspection.
