{
  pkgs,
  lib,
  clusterConfig,
  ...
}: let
  nodeNames = builtins.attrNames clusterConfig.nodes;
  nodeRecipients =
    lib.concatMapStringsSep " "
    (n: "-R keys/hosts/${n}/ssh_host_ed25519_key.pub")
    nodeNames;
in
  pkgs.writeShellScriptBin "secrets" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    [[ -f keys/admin.pub ]] || {
      log secrets "Missing keys/admin.pub"
      echo "Generate with: ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin -N \"\" && cp ~/.ssh/k3s-admin.pub keys/"
      exit 1
    }

    mkdir -p secrets/wireguard

    ${lib.concatStringsSep "\n" (map (n: ''
        [[ -f keys/hosts/${n}/ssh_host_ed25519_key ]] || {
          mkdir -p keys/hosts/${n}
          ${pkgs.openssh}/bin/ssh-keygen -t ed25519 -N "" -f keys/hosts/${n}/ssh_host_ed25519_key -C "${n}"
        }
      '')
      nodeNames)}

    [[ -f secrets/k3s-token.age ]] || {
      ${pkgs.openssl}/bin/openssl rand -hex 32 \
        | ${pkgs.age}/bin/age -R keys/admin.pub ${nodeRecipients} -o secrets/k3s-token.age
      log secrets "Created k3s-token.age"
    }

    ${lib.concatStringsSep "\n" (map (n: ''
        [[ -f secrets/wireguard/${n}.age ]] || {
          priv=$(${pkgs.wireguard-tools}/bin/wg genkey)
          echo "$priv" \
            | ${pkgs.age}/bin/age -R keys/admin.pub -R keys/hosts/${n}/ssh_host_ed25519_key.pub \
                -o secrets/wireguard/${n}.age
          echo "$priv" | ${pkgs.wireguard-tools}/bin/wg pubkey > secrets/wireguard/${n}.pub
          log secrets "Created wireguard/${n}.{age,pub}"
        }
      '')
      nodeNames)}

    log secrets "Done. Commit with: git add -A && git commit -m 'secrets'"
  ''
