{
  lib,
  self,
  ...
}:
# self must be added to specialArgs in flake.nix
{
  users.users = {
    root = {
      initialHashedPassword = lib.mkForce null;
      hashedPassword = lib.mkForce "!";
    };
    admin = {
      isNormalUser = true;
      hashedPassword = "!";
      extraGroups = ["wheel"];
      openssh.authorizedKeys.keyFiles = [
        "${self}/secrets/admin.pub"
      ];
    };
  };

  users.groups.admin = {};
  security.sudo.wheelNeedsPassword = false;
}
