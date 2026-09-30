# Every node: identity, SSH, admin access, Nix housekeeping.
# Role-specific parts live in the imported modules; lib/default.nix adds
# vm.nix or lxc.nix for the platform.
{
  lib,
  pkgs,
  inputs,
  cluster,
  node,
  secrets,
  ...
}: {
  imports = [
    inputs.agenix.nixosModules.default
    ./network.nix
    ./k3s.nix
    ./network-policy.nix
    ./storage.nix
    ./gpu.nix
    ./loadbalancer.nix
  ];

  system.stateVersion = cluster.stateVersion;

  users = {
    # Accounts and keys come only from this configuration.
    mutableUsers = false;
    users.root = {
      initialHashedPassword = lib.mkForce null;
      hashedPassword = lib.mkForce "!";
    };
    users.admin = {
      isNormalUser = true;
      hashedPassword = "!";
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keyFiles = [(secrets + "/admin.pub")];
    };
  };
  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable = true;
    ports = [node.sshPort];
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    # Only the keys in admin.pub; ~/.ssh/authorized_keys is ignored.
    authorizedKeysInHomedir = false;
    settings = {
      AllowUsers = ["admin"];
      AuthenticationMethods = "publickey";
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      AllowAgentForwarding = false;
    };
  };
  # The managed host key doubles as the agenix identity.
  age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];

  nix = {
    settings = {
      trusted-users = ["@wheel"];
      auto-optimise-store = true;
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  documentation.enable = false;
  environment.defaultPackages = [];
  environment.systemPackages = [pkgs.wireguard-tools];
}
