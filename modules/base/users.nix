{self, ...}:
# self must be added to specialArgs in flake.nix
{
  users.users = {
    nixos = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keyFiles = [
        "${self}/keys/admin.pub"
      ];
    };
    admin = {
      isSystemUser = true;
      group = "admin";
      password = "admin"; # Proxmox only so it's safe
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keyFiles = [
        "${self}/keys/admin.pub"
      ];
    };
  };

  users.groups.admin = {};
  security.sudo.wheelNeedsPassword = false;
}
