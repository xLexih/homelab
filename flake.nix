{
  description = "NixOS K3s HA Cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    nix-index-database.url = "github:nix-community/nix-index-database";
    nix-index-database.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    lib = nixpkgs.lib;

    root = ./.;

    mkCluster = import ./lib/mkCluster.nix;

    home = mkCluster {
      inherit lib pkgs self inputs system root;
      configPath = ./config/home.nix;
    };

    teddysmp = mkCluster {
      inherit lib pkgs self inputs system root;
      configPath = ./config/teddysmp.nix;
    };

    mergeUnique = label: left: right: let
      duplicates = lib.intersectLists (builtins.attrNames left) (builtins.attrNames right);
    in
      if duplicates == []
      then left // right
      else throw "Duplicate ${label}: ${lib.concatStringsSep ", " duplicates}";

    packages = mergeUnique "package names" home.packages.${system} teddysmp.packages.${system};

    homeCluster =
      (lib.evalModules {
        modules = [
          ./modules/base/options.nix
          ./config/home.nix
        ];
      }).config.cluster;

    validate = cluster: (import ./lib/helpers.nix {inherit lib cluster;}).validateCluster;

    invalidClusters = [
      (lib.recursiveUpdate homeCluster {
        network.wgCIDR = "10.100.16.0/20";
      })
      (lib.recursiveUpdate homeCluster {
        network.serviceCIDR = homeCluster.network.podCIDR;
      })
      (lib.recursiveUpdate homeCluster {
        nodes.master2.podCIDR = "10.42.0.128/25";
      })
      (homeCluster
        // {
          nodes = builtins.removeAttrs homeCluster.nodes ["master3"];
        })
    ];

    formatter = pkgs.writeShellApplication {
      name = "cluster-format";
      runtimeInputs = [
        pkgs.alejandra
        pkgs.findutils
      ];
      text = ''
        if (( $# > 0 )); then
          exec alejandra "$@"
        fi
        find . \( -path ./apps -o -path ./.git -o -path ./.direnv \) -prune \
          -o -name '*.nix' -print0 | xargs -0 alejandra
      '';
    };

    nixFiles = lib.filter (
      path:
        lib.hasSuffix ".nix" (toString path)
        && !(lib.hasInfix "/apps/" (toString path))
    ) (lib.filesystem.listFilesRecursive root);
  in {
    nixosConfigurations = mergeUnique "node names" home.nixosConfigurations teddysmp.nixosConfigurations;
    packages.${system} = packages;

    formatter.${system} = formatter;

    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        alejandra
        deadnix
        shellcheck
        statix
      ];
    };

    checks.${system} = {
      formatting =
        pkgs.runCommand "check-nix-formatting" {
          nativeBuildInputs = [pkgs.alejandra];
        } ''
          alejandra --check ${lib.escapeShellArgs (map toString nixFiles)}
          touch "$out"
        '';

      shell =
        pkgs.runCommand "check-cluster-shell-tools" {
          nativeBuildInputs = [pkgs.shellcheck];
        } ''
          shellcheck \
            ${packages.deploy-home}/bin/deploy \
            ${packages.image-home}/bin/image \
            ${packages.secrets-home}/bin/secrets \
            ${packages.config-home}/bin/get-kubeconfig
          touch "$out"
        '';

      static =
        pkgs.runCommand "check-nix-static-analysis" {
          nativeBuildInputs = [
            pkgs.deadnix
            pkgs.statix
          ];
        } ''
          for file in ${lib.escapeShellArgs (map toString nixFiles)}; do
            deadnix --fail "$file"
            statix check "$file"
          done
          touch "$out"
        '';

      validation = assert lib.all (cluster: !(validate cluster).valid) invalidClusters;
        pkgs.runCommand "check-cluster-validation" {} ''
          touch "$out"
        '';
    };
  };
}
