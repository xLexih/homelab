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
    inputs.nix-index-database.nixosModules.default
    ./network.nix
    ./k3s.nix
    ./cilium.nix
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
      experimental-features = ["nix-command" "flakes"];
      trusted-users = ["@wheel"];
      auto-optimise-store = true;
    };
    # nixpkgs comes from the flake the node was built from
    channel.enable = false;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
  };

  programs = {
    # Prompt from ~/dotfiles: [user:path]$ locally, [user@host:path]$ over SSH.
    bash.promptInit = ''
      if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CONNECTION" ]; then
        # SSH
        export PS1='\[\033[38;5;241m\][\[\033[38;5;212m\]\u@\h\[\033[38;5;241m\]:\[\033[38;5;141m\]\w\[\033[38;5;241m\]]\[\033[38;5;212m\]\$\[\033[0m\] '
      else # LOCAL
        export PS1='\[\033[38;5;241m\][\[\033[38;5;141m\]\u\[\033[38;5;241m\]:\[\033[38;5;84m\]\w\[\033[38;5;241m\]]\[\033[38;5;212m\]\$\[\033[0m\] '
      fi
    '';

    # `, <command>` runs any nixpkgs program once without installing it, and
    # an unknown command names the package that has it. Both use the prebuilt
    # index, and `nix shell nixpkgs#…` resolves to the nixpkgs the node runs.
    nix-index-database.comma.enable = true;
    git.enable = true; # flakes fetch git repositories
  };

  documentation.enable = false;
  environment.defaultPackages = [];

  environment.systemPackages = with pkgs; [
    wireguard-tools
    # processes and resources
    htop
    btop
    iotop
    lsof
    strace
    sysstat
    # network
    dnsutils
    tcpdump
    mtr
    iperf3
    ethtool
    conntrack-tools
    nmap
    socat
    curl
    # disks and hardware
    ncdu
    smartmontools
    pciutils
    usbutils
    # files and data
    jq
    yq-go
    tree
    file
    vim
    tmux
  ];
}
