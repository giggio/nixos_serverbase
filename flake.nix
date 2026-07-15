{
  description = "NixOS configuration";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    disko = {
      url = "github:nix-community/disko/latest";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-utils,
      ...
    }:
    let
      lib = nixpkgs.lib;
      machines = [
        {
          name = "pi4";
          defaultArch = "aarch64";
          hardwareModule = self.nixosModules.hardware.pi4 { };
          modules = [ ./configuration.nix ];
          supportsIso = false;
          supportsImg = true;
        }
        {
          name = "gmktec1";
          defaultArch = "x86_64";
          hardwareModule = self.nixosModules.hardware.gmktec { };
          modules = [ ./configuration.nix ];
          supportsIso = true;
          supportsImg = false;
          vmMemorySize = 8;
          vmDiskSize = 48;
          useEFIBoot = true;
        }
        {
          name = "opi4pro";
          defaultArch = "aarch64";
          hardwareModule = self.nixosModules.hardware.opi4pro { };
          modules = [ ./configuration.nix ];
          supportsIso = false;
          supportsImg = true;
          extraDisks = [
            100
            100
            100
          ];
          # The _img packages for this machine are UNATTENDED INSTALLER images, not full-system images: the SD card boots an
          # installer that wipes /dev/nvme0n1 with disko and installs this machine system onto it, pulling the pre-built
          # closure from the attic cache. The SD card then stays in the board permanently, holding only the boot chain (the
          # SoC boot ROM cannot boot from NVMe). See modules/setup-opi4pro.nix.
          imgIsInstaller = true;
        }
      ];
      nixosConfigurations = self.nixosModules.lib.mkNixosConfigurations machines;
    in
    {
      inherit nixosConfigurations;
      nixosModules = import ./modules/default.nix {
        inherit inputs lib;
        modules = self.nixosConfigurations;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        formatter = pkgs.nixfmt-tree;
        checks = {
          boot-test = pkgs.testers.nixosTest (import ./tests/default.nix { inherit pkgs inputs; });
        };
        packages = {
          list_machines = self.nixosModules.lib.list_machines { inherit pkgs machines; };
        }
        // self.nixosModules.lib.machine_details { inherit pkgs machines; }
        // self.nixosModules.lib.mkInstallerPackages {
          inherit nixosConfigurations machines;
        };
        devShells = self.nixosModules.lib.mkDevShells {
          inherit pkgs;
          inherit system;
        };
      }
    );
}
