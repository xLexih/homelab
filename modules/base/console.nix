{
  config,
  lib,
  nodeConfig,
  nodeName,
  ...
}: let
  isLxc = nodeConfig.platform == "lxc";
in {
  console.enable = true;

  services.getty = {
    greetingLine = "∴ ${nodeName} · NixOS ${config.system.nixos.release} (\\m) · \\l";
    helpLine = lib.mkIf isLxc (lib.mkForce "Proxmox LXC console → admin");
    autologinUser = lib.mkIf isLxc "admin";
  };

  systemd.services.console-getty = lib.mkIf isLxc {
    enable = true;
    wantedBy = ["getty.target"];
  };
}
