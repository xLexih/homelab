{
  description = "template - development environment";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  outputs = { nixpkgs, ... }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [ just kubectl kustomize docker-client gettext ];
      shellHook = ''
        echo "template devShell: just, kubectl, kustomize, docker ready"
      '';
    };
  };
}
