{
  description = "NixOS configuration";
  inputs = {
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, nixos-hardware, nixos-generators, ... }:
    let
      lib = nixpkgs.lib;
      mkNixosSystem = { specialArgs, ... }: nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          ./configuration.nix
          nixos-hardware.nixosModules.raspberry-pi-4
        ];
        specialArgs = { } // specialArgs;
      };
      setup = {
        virtualbox = false;
      };
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt; # todo: remove x86_64-linux
      nixosConfigurations = {
        nixos = mkNixosSystem {
          specialArgs = { inherit setup; };
        };
        nixos_virtualbox = mkNixosSystem {
          specialArgs = { setup = setup // { virtualbox = true; }; };
        };
      };
      packages.x86_64-linux = {
        vbox = nixos-generators.nixosGenerate {
          system = "x86_64-linux";
          format = "virtualbox";
          modules = [
            ./configuration.nix
          ];
          specialArgs = { setup = setup // { virtualbox = true; }; };
        };
      };
    };
}
