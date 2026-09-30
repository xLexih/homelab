{
  description = "NixOS k3s clusters: one directory per cluster under clusters/";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
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

    # Expected validation error (substring) -> broken variant of the home cluster.
    invalid = let
      home = import ./clusters/home/cluster.nix;
      set = lib.recursiveUpdate home;
    in {
      "odd number of servers" = home // {nodes = removeAttrs home.nodes ["master3"];};
      "`init` must name" = removeAttrs home ["init"];
      "inside network.wgCIDR" = set {nodes.master2.wgIP = "10.200.0.2";};
      "must be unique" = set {nodes.master2.wgIP = "10.100.0.1";};
      "must not overlap" = set {network.serviceCIDR = "10.42.128.0/17";};
      "need `dataDisk`" = set {nodes.master2.dataDisk = null;};
      "vip must be inside" = home // {vip = "10.9.9.9";};
    };
    rejected = expected: definition: let
      errors = clusterLib.validate (clusterLib.evalCluster "test" definition);
    in
      lib.any (lib.hasInfix expected) errors
      || throw "validation should report '${expected}', got: ${builtins.toJSON errors}";
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
        validation = assert lib.all (x: x) (lib.mapAttrsToList rejected invalid);
          pkgs.runCommand "validation" {} "touch $out";
      };
  };
}
