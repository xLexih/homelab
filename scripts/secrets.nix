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
  nodeRecipients =
    lib.concatMapStringsSep " "
    (n: "-R secrets/hosts/${n}/ssh-key.pub")
    nodeNames;
  age = "${pkgs.age}/bin/age";
  mktemp = "${pkgs.coreutils}/bin/mktemp";
  mv = "${pkgs.coreutils}/bin/mv";
  rm = "${pkgs.coreutils}/bin/rm";
  ssh-keygen = "${pkgs.openssh}/bin/ssh-keygen";
  wg = "${pkgs.wireguard-tools}/bin/wg";
  openssl = "${pkgs.openssl}/bin/openssl";
in
  pkgs.writeShellScriptBin "secrets" ''
    set -euo pipefail
    log() { echo "[$(date '+%H:%M:%S')] [$1] $2"; }

    rekey_file() {
      local source="$1" tmp
      shift
      tmp=$(${mktemp} "$source.tmp.XXXXXX")
      if ! ${age} -d -i ~/.ssh/k3s-admin "$source" | ${age} "$@" -o "$tmp"; then
        ${rm} -f "$tmp"
        return 1
      fi
      ${mv} "$tmp" "$source"
    }

    [[ -f secrets/admin.pub ]] || {
      log init "ERROR: Missing secrets/admin.pub"
      echo "Generate: ssh-keygen -t ed25519 -f ~/.ssh/k3s-admin -N \"\" && cp ~/.ssh/k3s-admin.pub secrets/admin.pub"
      exit 1
    }

    usage() {
      echo "Usage: secrets <command>"
      echo ""
      echo "Commands:"
      echo "  init      Generate host keys, secrets, and encrypted backups"
      echo "  rekey     Re-encrypt all secrets with current public keys"
      echo "  encrypt   Encrypt plaintext host keys back to .age files"
      echo "  restore   Decrypt .age host keys to plaintext (temp use)"
    }

    cmd_init() {
      mkdir -p secrets/hosts

      ${lib.concatStringsSep "\n" (map (n: ''
        mkdir -p secrets/hosts/${n}
        if [[ ! -s secrets/hosts/${n}/ssh-key.pub ]] && [[ -f secrets/hosts/${n}/ssh-key.age ]]; then
          tmp=$(mktemp -d)
          ${age} -d -i ~/.ssh/k3s-admin secrets/hosts/${n}/ssh-key.age > "$tmp/key"
          chmod 600 "$tmp/key"
          ${ssh-keygen} -y -f "$tmp/key" > secrets/hosts/${n}/ssh-key.pub
          ${rm} -rf "$tmp"
          log init "Recovered host public key for ${n}"
        elif [[ ! -s secrets/hosts/${n}/ssh-key.pub ]]; then
          tmp=$(mktemp -d)
          ${ssh-keygen} -t ed25519 -N "" -f "$tmp/key" -C "${n}" >/dev/null
          mv "$tmp/key.pub" secrets/hosts/${n}/ssh-key.pub
          ${age} -R secrets/admin.pub -o secrets/hosts/${n}/ssh-key.age "$tmp/key"
          ${rm} -rf "$tmp"
          log init "Generated host key for ${n}"
        elif [[ ! -f secrets/hosts/${n}/ssh-key.age ]]; then
          log init "ERROR: Missing encrypted host key backup for ${n}"
          exit 1
        fi
      '')
      nodeNames)}

      [[ -f secrets/k3s-token.age ]] || {
        ${openssl} rand -hex 32 \
          | ${age} -R secrets/admin.pub ${nodeRecipients} -o secrets/k3s-token.age
        log init "Created k3s-token.age"
      }

      ${lib.concatStringsSep "\n" (map (n: ''
        if [[ -f secrets/hosts/${n}/wireguard.age ]] && [[ ! -s secrets/hosts/${n}/wireguard.pub ]]; then
          ${age} -d -i ~/.ssh/k3s-admin secrets/hosts/${n}/wireguard.age \
            | ${wg} pubkey > secrets/hosts/${n}/wireguard.pub
          log init "Recovered hosts/${n}/wireguard.pub"
        elif [[ ! -f secrets/hosts/${n}/wireguard.age ]]; then
          priv=$(${wg} genkey)
          echo "$priv" \
            | ${age} -R secrets/admin.pub -R secrets/hosts/${n}/ssh-key.pub \
                -o secrets/hosts/${n}/wireguard.age
          echo "$priv" | ${wg} pubkey > secrets/hosts/${n}/wireguard.pub
          log init "Created hosts/${n}/wireguard.{age,pub}"
        fi
      '')
      nodeNames)}

      log init "Done"
    }

    cmd_encrypt() {
      ${lib.concatStringsSep "\n" (map (n: ''
        if [[ -f secrets/hosts/${n}/ssh-key.plaintext ]]; then
          ${age} -R secrets/admin.pub -o secrets/hosts/${n}/ssh-key.age \
            secrets/hosts/${n}/ssh-key.plaintext
          rm secrets/hosts/${n}/ssh-key.plaintext
          log encrypt "Encrypted ${n}/ssh-key"
        fi
      '')
      nodeNames)}
    }

    cmd_restore() {
      ${lib.concatStringsSep "\n" (map (n: ''
        if [[ -f secrets/hosts/${n}/ssh-key.age ]]; then
          ${age} -d -i ~/.ssh/k3s-admin secrets/hosts/${n}/ssh-key.age \
            > secrets/hosts/${n}/ssh-key.plaintext
          chmod 600 secrets/hosts/${n}/ssh-key.plaintext
          log restore "Decrypted ${n}/ssh-key.plaintext"
        else
          log restore "SKIP ${n} — no backup"
        fi
      '')
      nodeNames)}
      echo "Plaintext keys written. Run 'secrets encrypt' after use to re-encrypt and remove."
    }

    cmd_rekey() {
      log rekey "Re-encrypting all secrets..."

      rekey_file secrets/k3s-token.age -R secrets/admin.pub ${nodeRecipients}
      log rekey "k3s-token.age"

      ${lib.concatStringsSep "\n" (map (n: ''
        [[ -f secrets/hosts/${n}/ssh-key.age ]] && {
          rekey_file secrets/hosts/${n}/ssh-key.age -R secrets/admin.pub
          log rekey "hosts/${n}/ssh-key.age"
        }
        [[ -f secrets/hosts/${n}/wireguard.age ]] && {
          rekey_file secrets/hosts/${n}/wireguard.age \
            -R secrets/admin.pub -R secrets/hosts/${n}/ssh-key.pub
          log rekey "hosts/${n}/wireguard.age"
        }
      '')
      nodeNames)}

      log rekey "Done"
    }

    case "''${1:-}" in
      init)    cmd_init ;;
      encrypt) cmd_encrypt ;;
      restore) cmd_restore ;;
      rekey)   cmd_rekey ;;
      -h|--help) usage ;;
      *) usage; exit 1 ;;
    esac
  ''
