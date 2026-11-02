{
  description = "NixOS k3s clusters: one directory per cluster under clusters/";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-26.05/nixexprs.tar.zst";
    # only for the k3s package (modules/k3s.nix)
    nixpkgs-unstable.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # prebuilt package index for comma and command-not-found on the nodes
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    ...
  } @ inputs: let
    inherit (nixpkgs) lib;
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    clusterLib = import ./lib {inherit inputs lib pkgs;};

    clusters =
      lib.mapAttrs (name: _: clusterLib.mkCluster name (./clusters + "/${name}"))
      (lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./clusters));
  in {
    nixosConfigurations = lib.concatMapAttrs (_: c: c.nixosConfigurations) clusters;
    packages.${system} = lib.mapAttrs (_: c: c.cli) clusters;

    formatter.${system} = pkgs.writeShellScriptBin "fmt" ''exec ${lib.getExe pkgs.alejandra} "''${@:-.}"'';

    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [age alejandra deadnix statix];
    };

    checks.${system} =
      # Building a CLI runs ShellCheck on it.
      lib.mapAttrs' (name: c: lib.nameValuePair "cli-${name}" c.cli) clusters
      // {
        lint = pkgs.runCommand "lint" {nativeBuildInputs = with pkgs; [alejandra deadnix statix];} ''
          alejandra --check ${self}
          deadnix --fail ${self}
          statix check ${self}
          touch $out
        '';
        validation = import ./tests/validation.nix {inherit lib pkgs clusterLib;};
        # Every chart the servers fetch and every manifest they write. Small,
        # and the only way to catch a wrong chart hash before a deploy.
        charts = let
          servers = lib.filter (k: k.role == "server") (map (n: n.config.services.k3s) (lib.attrValues self.nixosConfigurations));
          paths = lib.concatMap (k:
            lib.concatMap (c: [c.package c.source]) (lib.attrValues k.autoDeployCharts)
            ++ map (m: m.source) (lib.filter (m: m.enable) (lib.attrValues k.manifests)))
          servers;
        in
          pkgs.runCommand "charts" {paths = lib.unique (map toString paths);} "touch $out";
        vm = import ./tests {inherit inputs lib pkgs clusterLib;};
      };
  };
}
