{ lib, pkgs, self, inputs, root, configPath, system ? "x86_64-linux" }:
let
  clusterEval = lib.evalModules {
    modules = [
      (root + "/modules/base/options.nix")
      configPath
    ];
  };
  clusterConfig = clusterEval.config.cluster;

  helpers = import (root + "/lib/helpers.nix") {
    inherit lib;
    cluster = clusterConfig;
  };
in
  if !helpers.validateCluster.valid
  then throw "Cluster validation failed:\n${lib.concatStringsSep "\n" helpers.validateCluster.errors}"
  else {
    nixosConfigurations = lib.mapAttrs (name: nodeCfg:
      lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit self clusterConfig helpers;
          helmDefaults = import (root + "/modules/kubernetes/helm-lib.nix") { inherit pkgs lib; };
          nodeName = name;
          nodeConfig = nodeCfg;
        };
        modules =
          lib.optionals (nodeCfg.platform == "vm") [
            inputs.disko.nixosModules.disko
            (root + "/modules/hardware")
          ]
          ++ lib.optionals (nodeCfg.platform == "lxc") [
            (inputs.nixpkgs + "/nixos/modules/virtualisation/lxc-container.nix")
          ]
          ++ [
            inputs.agenix.nixosModules.default
            inputs.nix-index-database.nixosModules.nix-index
            (root + "/modules/base")
            (root + "/modules/network")
            (root + "/modules/kubernetes")
            (root + "/modules/hardware/gpu/device-plugin.nix")
            (root + "/modules/cni")
            (root + "/modules/storage")
            (root + "/modules/loadbalancer")
            (root + "/modules/registry")
            { programs.nix-index-database.comma.enable = true; }
          ];
      })
    clusterConfig.nodes;

    packages = {
      "${system}" = {
        "deploy-${clusterConfig.name}" = pkgs.callPackage (root + "/scripts/deploy.nix") { inherit clusterConfig; };
        "image-${clusterConfig.name}" = pkgs.callPackage (root + "/scripts/image.nix") { inherit clusterConfig; };
        "secrets-${clusterConfig.name}" = pkgs.callPackage (root + "/scripts/secrets.nix") { inherit clusterConfig; };
        "config-${clusterConfig.name}" = pkgs.callPackage (root + "/scripts/get-kubeconfig.nix") { inherit clusterConfig; };
      };
    };
  }
