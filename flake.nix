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
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-secrets = {
      url = "path:/home/giggio/.config/nixos-secrets";
      flake = false;
    };
  };

  outputs = inputs@{ nixpkgs, home-manager, nixos-hardware, nixos-generators, sops-nix, ... }:
    let
      lib = nixpkgs.lib;
      setup = {
        user = "giggio";
        virtualbox = false;
        isBuildingImage = false;
      };
      baseModules = [
        ./configuration.nix
        sops-nix.nixosModules.sops
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            users.${setup.user} = ./home.nix;
            extraSpecialArgs = { inherit setup; };
            sharedModules = [ ];
          };
        }
      ];
      baseSpecialArgs = { inherit inputs; };
      mkNixosSystem = { specialArgs, system, ... }: let
        modules = baseModules ++ (if specialArgs.setup.virtualbox then [
        ] else [
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"
          nixos-hardware.nixosModules.raspberry-pi-4
            ({ config, pkgs, lib, ... }: {
              boot.kernelPackages = pkgs.linuxPackages_6_12;
            })
        ]);
      in nixpkgs.lib.nixosSystem {
        inherit system;
        modules = modules;
        specialArgs = baseSpecialArgs // specialArgs;
      };
    in
    {
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixpkgs-fmt; # todo: remove x86_64-linux
      images.pi4 = (mkNixosSystem {
          system = "aarch64-linux";
          specialArgs = { setup = setup // { isBuildingImage = true; }; };
        }).config.system.build.sdImage;
      nixosConfigurations = {
        nixos = mkNixosSystem {
          system = "aarch64-linux";
          specialArgs = { inherit setup; };
        };
        nixos_virtualbox = mkNixosSystem {
          system = "x86_64-linux";
          specialArgs = { setup = setup // { virtualbox = true; }; };
        };
      };
      packages.x86_64-linux = let
        packagingSetup = setup // { isBuildingImage = true; };
      in  {
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
          specialArgs = baseSpecialArgs // { setup = packagingSetup // { virtualbox = true; }; };
        };
      };
    };
}
