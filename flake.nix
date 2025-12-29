{
  description = "NixOS configuration";
  inputs = {
    # nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, nixos-hardware, nixos-generators, ... }:
    let
      lib = nixpkgs.lib;
      baseModules = [
        ./configuration.nix
        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.giggio = ./home.nix;
          home-manager.extraSpecialArgs = { };
        }
      ];
      mkNixosSystem = { specialArgs, ... }: nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = baseModules ++ [
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
          modules = baseModules;
          specialArgs = { setup = setup // { virtualbox = true; }; };
        };
      };
    };
}
