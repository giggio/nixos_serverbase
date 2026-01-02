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
              boot.kernelPackages = pkgs.linuxPackages_latest; # todo: evaluate if we should use the vendored kernel: pkgs.linuxKernel.packages.linux_rpi4 or pkgs.linuxPackages_rpi4
              boot.supportedFilesystems.zfs = lib.mkForce false; # todo: remove this when zfs is supported
              boot.kernelModules = [ "bcm2835-v4l2" ]; # originally missing, as we are not using the vendored kernel
              boot.kernelParams = lib.mkForce [ # removing console=ttyAMA0,115200n8, which breaks Pi4's Bluetooth
                "console=ttyS0,115200n8"
                "console=tty0"
                "loglevel=7"
                "lsm=landlock,yama,bpf"
              ];

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
