{
  description = "NixOS K3s HA Cluster";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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

    # Single evaluation of the cluster options + config
    clusterEval = lib.evalModules {
      modules = [
        ./modules/base/options.nix
        ./config/production.nix
      ];
    };
    clusterConfig = clusterEval.config.cluster;

    helpers = import ./lib/helpers.nix {
      inherit lib;
      cluster = clusterConfig;
    };
  in
    # Fail early if the cluster definition is invalid
    if !helpers.validateCluster.valid
    then throw "Cluster validation failed:\n${lib.concatStringsSep "\n" helpers.validateCluster.errors}"
    else {
      nixosConfigurations = lib.mapAttrs (name: nodeCfg:
        lib.nixosSystem {
          inherit system;
          specialArgs = {
            inherit self clusterConfig helpers;
            helmDefaults = import ./modules/kubernetes/helm-lib.nix {inherit pkgs lib;};
            nodeName = name;
            nodeConfig = nodeCfg;
          };
          modules = [
            inputs.disko.nixosModules.disko
            inputs.agenix.nixosModules.default
            inputs.nix-index-database.nixosModules.nix-index
            ./modules/base
            ./modules/network
            ./modules/hardware
            ./modules/kubernetes
            ./modules/cni
            ./modules/storage
            ./modules/loadbalancer
            ./modules/registry
            {programs.nix-index-database.comma.enable = true;}
          ];
        })
      clusterConfig.nodes;

      packages.${system} = {
        deploy = pkgs.callPackage ./scripts/deploy.nix {inherit clusterConfig;};
        image = pkgs.callPackage ./scripts/image.nix {inherit clusterConfig;};
        secrets = pkgs.callPackage ./scripts/secrets.nix {inherit clusterConfig;};
        config = pkgs.callPackage ./scripts/get-kubeconfig.nix {inherit clusterConfig;};
      };
    };
}
