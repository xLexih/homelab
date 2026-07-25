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
  in {
    nixosConfigurations = home.nixosConfigurations // teddysmp.nixosConfigurations;
    packages.${system} = home.packages.${system} // teddysmp.packages.${system};
  };
}
