# Every node: identity, SSH, admin access, Nix housekeeping.
# Role- and platform-specific parts live in the imported modules.
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
    ./storage.nix
    ./gpu.nix
    ./loadbalancer.nix
    (
      if node.platform == "lxc"
      then ./lxc.nix
      else ./vm.nix
    )
  ];

  nixpkgs.hostPlatform = "x86_64-linux";
  system.stateVersion = cluster.stateVersion;

  users.users.root = {
    initialHashedPassword = lib.mkForce null;
    hashedPassword = lib.mkForce "!";
  };
  users.users.admin = {
    isNormalUser = true;
    hashedPassword = "!";
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keyFiles = [(secrets + "/admin.pub")];
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
    settings = {
      AllowUsers = ["admin"];
      KbdInteractiveAuthentication = false;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
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
