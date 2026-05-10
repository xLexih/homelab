{self, ...}: {
  services.openssh = {
    enable = true;
    hostKeys = [
      {
        path = "/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  age.identityPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  users.users.root.openssh.authorizedKeys.keyFiles = [
    "${self}/keys/admin.pub"
  ];
}
