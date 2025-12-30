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
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, nixos-hardware, nixos-generators, ... }:
    let
      lib = nixpkgs.lib;
      setup = {
        virtualbox = false;
        user = "giggio";
      };
      baseModules = [
        ./configuration.nix
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            users.${setup.user} = ./home.nix;
            extraSpecialArgs = { inherit setup; };
          };
        }
      ];
      baseSpecialArgs = { inherit inputs; };
      mkNixosSystem = { specialArgs, ... }: let
        modules = baseModules ++ (if specialArgs.setup.virtualbox then [
        ] else [
          nixos-hardware.nixosModules.raspberry-pi-4
        ]);
      in nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = modules;
        specialArgs = baseSpecialArgs // specialArgs;
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
          modules = baseModules ++ [
            {
              virtualbox = {
                vmName = "pitest";
                memorySize = 4096;
              };
            }
          ];
          specialArgs = baseSpecialArgs // { setup = setup // { virtualbox = true; }; };
        };
      };
    };
}
