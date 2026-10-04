# Disaster recovery

The examples use `home`; replace it with the cluster you're working on. Every
command runs from the repository root.

## What protects what

| key | where it lives | what it unlocks |
| --- | --- | --- |
| admin key (`~/.ssh/k3s-admin`) | your machine; public halves in `secrets/admin.pub` | SSH as `admin` (passwordless sudo) on every node, and decryption of every secret |
| node host key | `/etc/ssh/ssh_host_ed25519_key` on the node; a copy in `hosts/<node>/ssh-key.age` | the node's identity in `known_hosts`, and its agenix identity: it decrypts `k3s-token.age`, its own `wireguard.age`, and `etcd-s3.age` on servers |
| WireGuard key | `hosts/<node>/wireguard.age` | the node's place in the mesh |
| k3s token | `k3s-token.age` | joining the cluster as a node |

Secrets are encrypted for every key in `admin.pub` plus the host keys of the
nodes that need them. The host keys' own copies (`ssh-key.age`) are encrypted
for `admin.pub` only.

## Before anything goes wrong

- Keep a second admin key in `admin.pub`, stored somewhere else (another
  machine, a hardware token, an offline backup). With two keys, losing one is
  a routine rotation instead of a console session on every node.
- Set `etcdS3` so etcd snapshots leave the cluster; see
  [OPERATIONS.md](OPERATIONS.md#backups).
- Configure a Longhorn backup target for the volumes you care about.
- Push this repository somewhere. Everything in it is either public or
  encrypted.

## Rotating the admin key

When the old key still works, nothing goes offline:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin-new          # with a passphrase
cat ~/.ssh/k3s-admin-new.pub >> clusters/home/secrets/admin.pub
nix run .#home -- secrets sync      # re-encrypt for both keys (decrypts with the old one)
nix run .#home -- switch all        # nodes accept both keys

ssh-add -D && ssh-add ~/.ssh/k3s-admin-new
nix run .#home -- ssh master1 true  # the new key logs in

$EDITOR clusters/home/secrets/admin.pub                 # delete the old key's line
AGE_IDENTITY=~/.ssh/k3s-admin-new nix run .#home -- secrets sync
nix run .#home -- switch all        # the old key no longer logs in
mv ~/.ssh/k3s-admin-new ~/.ssh/k3s-admin && mv ~/.ssh/k3s-admin-new.pub ~/.ssh/k3s-admin.pub
```

Do it for every cluster, and commit. If the old key leaked, also assume its
holder copied the secrets. Rotate the node host keys, WireGuard keys and k3s
token as described below, since re-encrypting doesn't change their values.

The secret steps were rehearsed on 2026-10-04 against a copy of `home`: after
the second sync the new key decrypts every file and the old one is refused.

## One admin key lost, another still works

Treat it as a leak: run the rotation above with the remaining key as
`AGE_IDENTITY`, removing the lost key's line from `admin.pub`.

## Every admin key lost

Nothing can decrypt the secrets from your machine and nobody can log in, but
each node still holds its host key, which decrypts most of them. The plan is
to get a root shell on every node, copy its host key off, rebuild the secrets
for a new admin key, and let that key in.

### 1. Get a root shell on each node

LXC: on the Proxmox host, `pct enter <id>`.

VM: root has no password and the console doesn't log in. Attach a NixOS
installer ISO, boot from it, give the installer's root a password (`passwd`),
and mount the system:

```bash
vgchange -ay
mount /dev/vg0/root /mnt
mount /dev/disk/by-partlabel/disk-disk0-boot /mnt/boot
```

Copy each node's host key to your machine, e.g. as `~/recovery/host-<node>`
with mode 600. On LXC it's `/etc/ssh/ssh_host_ed25519_key`; from the
installer it's `/mnt/etc/ssh/ssh_host_ed25519_key`.

### 2. Rebuild the secrets for a new admin key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin
S=clusters/home/secrets
cp ~/.ssh/k3s-admin.pub $S/admin.pub

for n in master1 master2 master3; do
  age -R $S/admin.pub -o $S/hosts/$n/ssh-key.age < ~/recovery/host-$n
  AGE_IDENTITY=~/recovery/host-$n EDITOR=true nix run .#home -- secrets edit hosts/$n/wireguard.age
done
AGE_IDENTITY=~/recovery/host-master1 EDITOR=true nix run .#home -- secrets edit k3s-token.age
AGE_IDENTITY=~/recovery/host-master1 EDITOR=true nix run .#home -- secrets edit etcd-s3.age   # if etcdS3 is set; master1 must be a server

nix run .#home -- secrets sync      # passes only if the new key decrypts everything
```

`secrets edit` with `EDITOR=true` decrypts with the given host key and writes
the file back, unchanged, for the current recipients. The values of the
token, the WireGuard keys and the host keys stay the same, so the nodes and
the pinned `known_hosts` keep working. This was rehearsed on 2026-10-04
against a copy of `home`. Delete `~/recovery` afterwards.

### 3. Let the new key in

LXC, from the `pct enter` shell:

```bash
install -m 444 /dev/stdin /etc/ssh/authorized_keys.d/admin   # paste the new public key, then Ctrl-D
```

This lasts until the next activation. Run `nix run .#home -- switch <node>`
right away so the configuration carries the key from then on.

VM, from the installer: activation rewrites `/etc` at boot, so editing the
file isn't enough. Install the new configuration onto the mounted system
instead; it adds a generation and touches no data:

```bash
# on your machine
rsync -a ./ root@<installer-ip>:/root/cluster/
# in the installer, with the mounts from step 1
nixos-install --root /mnt --flake /root/cluster#home-master1 --no-root-passwd
reboot                                # remove the ISO first
```

The console steps in this section haven't been rehearsed on a live node yet.

## Rotating a node's host key

When a node's host key leaked or the node was compromised (rebuild it first
in that case):

```bash
S=clusters/home/secrets
cp $S/hosts/master2/ssh-key.pub /tmp/old-master2.pub
rm $S/hosts/master2/ssh-key.age $S/hosts/master2/ssh-key.pub
nix run .#home -- secrets sync        # new key; master2's secrets re-encrypted for it

# put the new key in place, trusting the old one for these last connections;
# the public half first, since sshd presents the new key after its restart
echo "192.168.2.106 $(cut -d' ' -f1-2 /tmp/old-master2.pub)" > /tmp/old-known
ssh -o UserKnownHostsFile=/tmp/old-known admin@192.168.2.106 \
  "echo '$(cat $S/hosts/master2/ssh-key.pub)' | sudo tee /etc/ssh/ssh_host_ed25519_key.pub >/dev/null"
age -d -i ~/.ssh/k3s-admin $S/hosts/master2/ssh-key.age |
  ssh -o UserKnownHostsFile=/tmp/old-known admin@192.168.2.106 \
    'sudo install -m 600 /dev/stdin /etc/ssh/ssh_host_ed25519_key && sudo systemctl restart sshd'

nix run .#home -- switch master2      # agenix decrypts with the new key
rm /tmp/old-master2.pub /tmp/old-known
```

The sync was rehearsed against a copy of `home`; the key replacement on a
live node wasn't. If the live part goes wrong, reinstall the node instead:
`install` places the new key before the first boot.

## Rotating a WireGuard key

```bash
rm clusters/home/secrets/hosts/master2/wireguard.{age,pub}
nix run .#home -- secrets sync
nix run .#home -- switch all
```

The node is cut off from the peers that haven't switched yet, so it's out of
the mesh until `switch all` finishes.

## Rotating the k3s token

Run the rotation on a server, then ship the new value right away: a node
restarting with the old token file fails once the rotation has happened.

```bash
new=$(od -An -tx1 -N32 /dev/urandom | tr -d ' \n')
nix run .#home -- ssh master1 "sudo k3s token rotate --token \$(sudo cat /run/agenix/k3s-token) --new-token $new"
nix run .#home -- secrets edit k3s-token.age   # replace the content with $new
nix run .#home -- switch all
```

See the [k3s documentation](https://docs.k3s.io/cli/token).

## A node is gone

Use `remove` and, if you want it back, reinstall it; see
[OPERATIONS.md](OPERATIONS.md#adding-and-removing-nodes). `remove` works on a
dead node and also drops a dead server's etcd member. Its keys stay valid
unless you rotate them, so do that if the disk wasn't wiped.

## etcd lost quorum

With a majority of servers gone (two of three), the API stops answering. On
one surviving server, reset etcd to a single member, then let the others
rejoin empty
([k3s documentation](https://docs.k3s.io/datastore/backup-restore)):

```bash
# on the survivor
sudo systemctl stop k3s
systemctl cat k3s     # copy the ExecStart command line
sudo <that command> --cluster-reset                        # exits when done
# to go back to a snapshot instead, add
#   --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<name>
sudo systemctl start k3s

# on every other server
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db/etcd/*         # a mount point: empty it, keep it
sudo systemctl start k3s
```

Use the survivor's own ExecStart so the token and secrets-encryption settings
match; a restored snapshot can only be decrypted with the cluster's token.
Servers that are gone for good still have to be removed with `remove`. This
procedure hasn't been rehearsed on these clusters.

<div align="right">

Generated by Opus 5.5

</div>
